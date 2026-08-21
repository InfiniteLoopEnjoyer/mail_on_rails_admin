# A grant giving one web user (a member) access to one email account.
# Admins bypass grants entirely - see User#accessible_email_accounts.
class EmailAccountUser < ApplicationRecord
  belongs_to :user
  belongs_to :email_account, class_name: "MailOnRails::EmailAccount", inverse_of: :email_account_users

  validates :user_id, uniqueness: { scope: :email_account_id }
end
