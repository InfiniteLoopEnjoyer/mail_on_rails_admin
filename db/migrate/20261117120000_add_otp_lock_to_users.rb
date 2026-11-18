class AddOtpLockToUsers < ActiveRecord::Migration[8.1]
  def change
    change_table :users, bulk: true do |t|
      # Consecutive wrong authenticator codes since the last accepted one,
      # and the block they have earned (User#verify_otp). Kept on the row
      # the verification already locks, so the count and the check cannot
      # be raced apart, and so it survives restarts and source-IP changes.
      t.integer :otp_failed_attempts, null: false, default: 0
      t.datetime :otp_locked_until
    end
  end
end
