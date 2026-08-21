class AddRoleToUsers < ActiveRecord::Migration[8.1]
  def change
    add_column :users, :role, :string, null: false, default: "member"
    add_check_constraint :users, "role IN ('admin', 'member')", name: "users_role_check"

    # Everyone who exists at migration time is a full admin - that is the
    # documented pre-RBAC behavior. Only users created afterwards default
    # to member.
    reversible do |dir|
      dir.up { execute "UPDATE users SET role = 'admin'" }
    end
  end
end
