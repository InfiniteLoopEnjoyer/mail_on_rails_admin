namespace :active_storage do
  # One-off cleanup after closing the public Active Storage routes
  # (config.active_storage.draw_routes = false in config/application.rb).
  # While those routes were drawn, anyone could direct-upload a file with
  # no session; such a blob is never attached to a record. Everything the
  # app stores on purpose IS attached (Action Mailbox attaches each inbound
  # message's raw bytes to its InboundEmail), so "unattached" is exactly the
  # set that should not exist. Blobs younger than a day are left alone: an
  # inbound message's blob is created a moment before its attachment row.
  #
  #   bin/rails active_storage:purge_unattached            # list only
  #   PURGE=1 bin/rails active_storage:purge_unattached    # list and delete
  #
  # Lists first by default so the operator can look at what was there
  # (filename, type, size, upload time) before anything is removed.
  desc "List unattached Active Storage blobs older than a day; PURGE=1 deletes them (rows and files)"
  task purge_unattached: :environment do
    purge = ENV["PURGE"] == "1"
    scope = ActiveStorage::Blob.unattached.where(created_at: ...1.day.ago)
    count = 0
    bytes = 0

    scope.find_each do |blob|
      count += 1
      bytes += blob.byte_size
      puts [ blob.created_at.utc.iso8601, blob.byte_size, blob.content_type, blob.filename.sanitized.inspect ].join("  ")
      blob.purge if purge
    end

    summary = "#{count} unattached #{"blob".pluralize(count)}, #{ActiveSupport::NumberHelper.number_to_human_size(bytes)}"
    puts purge ? "Purged #{summary}." : "#{summary}. Nothing was deleted - re-run with PURGE=1 to delete."
  end
end
