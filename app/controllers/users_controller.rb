class UsersController < ApplicationController
  # Members manage only themselves (profile, password rotation, and the
  # 2FA-enrollment surface - see second_factor_enrollment_surface?);
  # set_user scopes them to their own record. User administration stays
  # admin-only, including self-deletion (account removal is an admin task).
  allow_member_access only: %i[edit update generate_password]
  before_action :set_user, only: %i[edit update destroy generate_password]
  # Step-up on every high-impact write: rotating a password (H1) and the
  # admin mutations of accounts/roles/grants (M2). A stolen session cookie
  # alone must not be able to do any of these.
  before_action :require_recent_reauthentication,
                only: %i[create update destroy generate_password]
  rate_limit to: 20, within: 10.minutes, only: %i[create update destroy generate_password],
             with: -> { redirect_to users_path, alert: "Try again later." }

  def index
    @users = User.order(:email_address)
  end

  def new
    @user = User.new
  end

  def create
    @user = User.new(user_params)
    @user.password = plaintext = User.generate_password
    if @user.save
      audit "user.create", @user
      flash[:generated_password] = plaintext
      redirect_to edit_user_path(@user), notice: "User #{@user.email_address} created."
    else
      render :new, status: :unprocessable_entity
    end
  end

  def edit
  end

  def update
    if demoting_last_admin?
      return redirect_to edit_user_path(@user), alert: "Cannot demote the last admin.", status: :see_other
    end

    if @user.update(user_params)
      details = { changes: @user.previous_changes.keys - %w[updated_at] }
      if user_params.key?(:email_account_ids)
        details[:granted_accounts] = @user.email_accounts.order(:email).pluck(:email)
      end
      audit "user.update", @user, **details
      redirect_to Current.user.admin? ? users_path : edit_user_path(@user), notice: "User updated."
    else
      render :edit, status: :unprocessable_entity
    end
  end

  def destroy
    # The only remaining user cannot be deleted - a web-only deployment has
    # no other way back in.
    if User.count == 1
      return redirect_to users_path, alert: "Cannot delete the only remaining user.", status: :see_other
    end

    # Nor the last admin - members can't reach the admin surfaces that
    # would mint another one.
    if @user.admin? && User.where(role: "admin").where.not(id: @user.id).none?
      return redirect_to users_path, alert: "Cannot delete the last admin.", status: :see_other
    end

    if @user == Current.user
      # Audit before the session dies, or the row would have no actor.
      audit "user.destroy", @user
      terminate_session
      @user.destroy!
      redirect_to new_session_path, notice: "Your account has been deleted.", status: :see_other
    else
      @user.destroy!
      audit "user.destroy", @user
      redirect_to users_path, notice: "User #{@user.email_address} deleted.", status: :see_other
    end
  end

  def generate_password
    plaintext = @user.regenerate_password!
    audit "user.generate_password", @user

    if @user == Current.user
      # Rotating your own password ends every session, this one included:
      # if the cookie was stolen, keeping the current session alive would
      # leave the attacker in place. The new plaintext rides the cookie
      # flash (which survives the DB-session teardown) to the sign-in page.
      @user.sessions.destroy_all
      terminate_session
      flash[:generated_password] = plaintext
      return redirect_to new_session_path,
                         notice: "Password changed - sign in with your new password.", status: :see_other
    end

    # An admin rotating another user's password: drop all of that user's
    # sessions (the admin's own is not among them).
    @user.sessions.destroy_all
    respond_to do |format|
      format.turbo_stream do
        render turbo_stream: turbo_stream.replace(
          "password-generator",
          partial: "shared/password_generator",
          locals: { url: generate_password_user_path(@user), password: plaintext }
        )
      end
      format.html do
        flash[:generated_password] = plaintext
        redirect_to edit_user_path(@user)
      end
    end
  end

  private

  def set_user
    # A member probing another user's id gets a 404, same as a nonexistent
    # one.
    scope = Current.user.admin? ? User.all : User.where(id: Current.user.id)
    @user = scope.find(params[:id])
  end

  # Role and grants are admin-only attributes - a member's crafted POST
  # can't self-promote or self-grant.
  def user_params
    if Current.user.admin?
      params.expect(user: [ :email_address, :role, email_account_ids: [] ])
    else
      params.expect(user: [ :email_address ])
    end
  end

  def demoting_last_admin?
    @user.admin? && user_params[:role] == "member" &&
      User.where(role: "admin").where.not(id: @user.id).none?
  end
end
