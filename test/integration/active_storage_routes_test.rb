require "test_helper"
require "rake"

# Active Storage is server-side plumbing here (Action Mailbox keeps each
# inbound message's bytes as a blob). Its stock routes sit outside
# ApplicationController - no session, no role check - so with them drawn
# anyone could upload files onto the mail volume and read them back from
# this hostname. config.active_storage.draw_routes = false removes them;
# these tests pin that, and that nothing the app does needed them.
class ActiveStorageRoutesTest < ActionDispatch::IntegrationTest
  def with_forgery_protection
    previous = ActionController::Base.allow_forgery_protection
    ActionController::Base.allow_forgery_protection = true
    yield
  ensure
    ActionController::Base.allow_forgery_protection = previous
  end

  test "the Active Storage routes are not drawn" do
    assert_equal false, Rails.application.config.active_storage.draw_routes
    paths = Rails.application.routes.routes.map { |route| route.path.spec.to_s }
    assert_empty paths.grep(%r{active_storage}), "no route may mention active_storage"
  end

  # The reviewer's exploit, step by step: CSRF token from the anonymous
  # login page, create the blob, PUT the bytes, read them back.
  test "an anonymous direct upload 404s even with a valid CSRF token" do
    with_forgery_protection do
      get new_session_path
      token = response.body[/name="csrf-token" content="([^"]+)"/, 1]
      assert token.present?
      data = "A" * 4096

      assert_no_difference -> { ActiveStorage::Blob.count } do
        post "/rails/active_storage/direct_uploads",
             params: { blob: { filename: "x.bin", byte_size: data.bytesize,
                               checksum: Digest::MD5.base64digest(data), content_type: "application/pdf" } },
             headers: { "X-CSRF-Token" => token }, as: :json
      end
      assert_response :not_found
    end
  end

  test "the upload, disk, blob and representation paths 404 for a real blob, signed in or not" do
    blob = ActiveStorage::Blob.create_and_upload!(io: StringIO.new("%PDF-1.4 fake"), filename: "statement.pdf",
                                                  content_type: "application/pdf", identify: false)
    disk_key = ActiveStorage.verifier.generate(
      { key: blob.key, disposition: "inline", content_type: blob.content_type, service_name: blob.service_name },
      purpose: :blob_key
    )
    upload_token = ActiveStorage.verifier.generate(
      { key: blob.key, content_type: blob.content_type, content_length: blob.byte_size,
        checksum: blob.checksum, service_name: blob.service_name },
      purpose: :blob_token
    )
    reads = [
      "/rails/active_storage/blobs/redirect/#{blob.signed_id}/statement.pdf",
      "/rails/active_storage/blobs/proxy/#{blob.signed_id}/statement.pdf",
      "/rails/active_storage/blobs/#{blob.signed_id}/statement.pdf",
      "/rails/active_storage/representations/redirect/#{blob.signed_id}/x/statement.pdf",
      "/rails/active_storage/representations/proxy/#{blob.signed_id}/x/statement.pdf",
      "/rails/active_storage/disk/#{disk_key}/statement.pdf"
    ]

    check = lambda do |who|
      reads.each do |path|
        get path
        assert_response :not_found, "#{who}: GET #{path[0, 60]}"
      end
      put "/rails/active_storage/disk/#{upload_token}", params: "%PDF-1.4 fake",
          headers: { "Content-Type" => "application/pdf" }
      assert_response :not_found, "#{who}: PUT disk"
      post "/rails/active_storage/direct_uploads", params: { blob: { filename: "x" } }, as: :json
      assert_response :not_found, "#{who}: POST direct_uploads"
    end

    check.call("anonymous")
    sign_in_as users(:one)
    check.call("signed-in admin")
  ensure
    blob&.purge
  end

  # The composer is the one page that loads an editor capable of direct
  # uploads (Lexxy imports @rails/activestorage lazily; the importmap pin
  # only keeps that import resolvable). It must render without the routes
  # and must not point the editor at them.
  test "the composer renders without the routes and offers no direct upload" do
    sign_in_as users(:one)
    MailOnRails::EmailAccount.create!(email: "writer@example.com", password: "secret123")

    get new_email_path

    assert_response :success
    assert_select "lexxy-editor[attachments=false]", 1
    assert_select "lexxy-editor[data-direct-upload-url]", 0
    assert_select "[data-direct-upload-url]", 0
    assert_no_match(%r{rails/active_storage}, response.body)
  end

  # Action Mailbox stores the raw message through Active Storage's model
  # layer, which needs no routes.
  test "Action Mailbox still stores and reads back an inbound message" do
    source = "From: a@remote.test\r\nTo: nobody@example.com\r\nSubject: stored\r\n" \
             "Message-ID: <as-routes@remote.test>\r\n\r\nbody\r\n"

    inbound = ActionMailbox::InboundEmail.create_and_extract_message_id!(source)

    assert inbound.raw_email.attached?
    assert_equal source, inbound.source
    assert_equal "stored", inbound.mail.subject
  end

  # lib/tasks/active_storage.rake - the one-off cleanup of whatever was
  # uploaded while the routes were open.
  test "purge_unattached lists by default and deletes only old unattached blobs with PURGE=1" do
    make = ->(name) { ActiveStorage::Blob.create_and_upload!(io: StringIO.new(name), filename: name, identify: false) }
    stale = make.call("stale.bin").tap { |b| b.update_columns(created_at: 2.days.ago) }
    fresh = make.call("fresh.bin")
    inbound = ActionMailbox::InboundEmail.create_and_extract_message_id!("Subject: kept\r\n\r\nx\r\n")
    inbound.raw_email.blob.update_columns(created_at: 2.days.ago)

    listing = run_purge_task
    assert_match(/stale\.bin/, listing)
    assert_match(/Nothing was deleted/, listing)
    assert ActiveStorage::Blob.exists?(stale.id), "the default run only lists"

    purged = with_env("PURGE" => "1") { run_purge_task }
    assert_match(/Purged 1 unattached blob/, purged)
    assert_not ActiveStorage::Blob.exists?(stale.id)
    assert_not stale.service.exist?(stale.key), "the file goes with the row"
    assert ActiveStorage::Blob.exists?(fresh.id), "younger than a day: left alone"
    assert ActiveStorage::Blob.exists?(inbound.raw_email.blob.id), "attached (inbound mail): never touched"
  ensure
    fresh&.purge
  end

  private
    # Just this one task file, in a throwaway Rake application with a no-op
    # :environment (the app is already loaded) - not Rails.application
    # .load_tasks, which would re-load every task file in the process.
    def run_purge_task
      output = nil
      Rake.with_application do
        Rake::Task.define_task(:environment)
        load Rails.root.join("lib/tasks/active_storage.rake")
        output, = capture_io { Rake::Task["active_storage:purge_unattached"].invoke }
      end
      output
    end

    def with_env(vars)
      previous = vars.to_h { |key, _| [ key, ENV[key] ] }
      vars.each { |key, value| ENV[key] = value }
      yield
    ensure
      previous.each { |key, value| value ? ENV[key] = value : ENV.delete(key) }
    end
end
