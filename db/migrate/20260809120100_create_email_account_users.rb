class CreateEmailAccountUsers < ActiveRecord::Migration[8.1]
  def change
    create_table :email_account_users do |t|
      t.references :user, null: false, foreign_key: true, index: true
      # Explicit to_table: on a fresh replay the account table already
      # carries the gem's prefix (the pre-rename "email_accounts" this
      # migration originally referenced no longer exists at this point in
      # history; existing databases got the same FK via the rename).
      t.references :email_account, null: false,
                   foreign_key: { to_table: :mail_on_rails_email_accounts }
      t.timestamps
    end
    add_index :email_account_users, [ :user_id, :email_account_id ], unique: true
  end
end
