class EmailAccountsController < ApplicationController
  # Members browse the accounts granted to them; account administration
  # (create/edit/delete, credential rotation) stays admin-only.
  allow_member_access only: %i[index show]
  before_action :set_email_account, only: %i[show edit update destroy generate_password]
  # Step-up on every mutation: rotating a mailbox password, marking an
  # account as a honeypot (which blackholes its mail), or rewriting a
  # vacation autoresponder must not be reachable with a stolen session
  # cookie alone - the same bar users, domains, and settings already set.
  before_action :require_recent_reauthentication,
                only: %i[create update destroy generate_password]
  rate_limit to: 20, within: 10.minutes, only: %i[create update destroy generate_password],
             with: -> { redirect_to root_path, alert: "Try again later." }

  def index
    domain_names = MailOnRails::Domain.pluck(:name).to_set
    groups = accessible_email_accounts.order(:email).includes(:mailboxes).group_by do |account|
      local, _, domain = account.email.partition("@")
      if domain_names.include?(domain) && local == MailOnRails::Domain::DMARC_LOCAL_PART
        :dmarc
      elsif domain_names.include?(domain) && local == MailOnRails::Domain::TLS_RPT_LOCAL_PART
        :tls_rpt
      elsif domain_names.include?(domain) && local == MailOnRails::Domain::POSTMASTER_LOCAL_PART
        :postmaster
      elsif domain_names.include?(domain) &&
            [ MailOnRails::Domain::FBL_LOCAL_PART, MailOnRails::Domain::UNSUBSCRIBE_LOCAL_PART,
              MailOnRails::Domain::BOUNCE_LOCAL_PART ].include?(local)
        # unsubscribe@ and bounce@ sit with the complaint accounts: all
        # three are the suppression-ingestion family (IngestFblReportJob /
        # IngestUnsubscribeJob / IngestBounceJob).
        :fbl
      else
        :regular
      end
    end
    @postmaster_accounts = groups.fetch(:postmaster, [])
    @fbl_accounts = groups.fetch(:fbl, [])
    @dmarc_accounts = groups.fetch(:dmarc, [])
    @tls_rpt_accounts = groups.fetch(:tls_rpt, [])
    @email_accounts = groups.fetch(:regular, [])
    @email_accounts.sort_by! { |account| local, _, domain = account.email.partition("@"); [ domain, local ] }
    @unseen_counts = MailOnRails::EmailMessage.joins(:mailbox)
                                 .where(MailOnRails::Mailbox.table_name => { email_account_id: accessible_email_accounts.select(:id) })
                                 .where.not("flags LIKE ?", "%Seen%")
                                 .group("#{MailOnRails::Mailbox.table_name}.email_account_id")
                                 .count
  end

  def show
    @mailboxes = @email_account.mailboxes.sort_by do |mailbox|
      [ MailOnRails::EmailAccount::DEFAULT_MAILBOXES.index(mailbox.name) || MailOnRails::EmailAccount::DEFAULT_MAILBOXES.length, mailbox.name ]
    end
  end

  def new
    @email_account = MailOnRails::EmailAccount.new
  end

  def create
    @email_account = MailOnRails::EmailAccount.new(email_account_params)
    @email_account.password = plaintext = MailOnRails::EmailAccount.generate_password
    if @email_account.save
      audit "email_account.create", @email_account
      flash[:generated_password] = plaintext
      redirect_to @email_account, notice: "Account #{@email_account.email} created."
    else
      render :new, status: :unprocessable_entity
    end
  end

  def edit
  end

  def update
    if @email_account.update(email_account_params)
      audit "email_account.update", @email_account, changes: @email_account.previous_changes.keys - %w[updated_at]
      redirect_to @email_account, notice: "Account updated."
    else
      render :edit, status: :unprocessable_entity
    end
  end

  def destroy
    @email_account.destroy!
    audit "email_account.destroy", @email_account
    redirect_to root_path, notice: "Account #{@email_account.email} deleted.", status: :see_other
  end

  def generate_password
    plaintext = @email_account.regenerate_password!
    audit "email_account.generate_password", @email_account
    respond_to do |format|
      format.turbo_stream do
        render turbo_stream: turbo_stream.replace(
          "password-generator",
          partial: "shared/password_generator",
          locals: { url: generate_password_email_account_path(@email_account), password: plaintext }
        )
      end
      format.html do
        flash[:generated_password] = plaintext
        redirect_to edit_email_account_path(@email_account)
      end
    end
  end

  private

  def set_email_account
    @email_account = accessible_email_accounts.find(params[:id])
  end

  def email_account_params
    params.expect(email_account: [ :email, :name, :quota_megabytes, :honeypot, :mailing_list,
                                   :vacation_enabled, :vacation_subject, :vacation_body,
                                   :vacation_starts_on, :vacation_ends_on ])
  end
end
