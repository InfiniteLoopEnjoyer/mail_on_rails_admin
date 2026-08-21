# frozen_string_literal: true

# Builds an edge-stamped inbound mail carrying a minimal TLS-RPT
# aggregate report for the example.test domain (5 good sessions, 1
# STARTTLS failure), gzipped the way real reporters send it.
module TlsRptReportMailHelper
  REPORT_JSON = <<~JSON
    {
      "organization-name": "google.com",
      "date-range": {
        "start-datetime": "2026-07-22T00:00:00Z",
        "end-datetime": "2026-07-22T23:59:59Z"
      },
      "contact-info": "smtp-tls-reporting@google.com",
      "report-id": "2026-07-22T00:00:00Z_example.test",
      "policies": [
        {
          "policy": {
            "policy-type": "sts",
            "policy-domain": "example.test",
            "policy-string": ["version: STSv1", "mode: testing"]
          },
          "summary": {
            "total-successful-session-count": 5,
            "total-failure-session-count": 1
          },
          "failure-details": [
            {
              "result-type": "starttls-not-supported",
              "sending-mta-ip": "198.51.100.20",
              "receiving-mx-hostname": "mx.example.test",
              "failed-session-count": 1
            }
          ]
        }
      ]
    }
  JSON

  def tls_report_mail(to)
    mail = Mail.new
    mail.from = "noreply-smtp-tls-reporting@google.com"
    mail.to = to
    mail.subject = "Report Domain: example.test Submitter: google.com"
    mail.text_part = Mail::Part.new(body: "attached")
    mail.attachments["google.com!example.test!1753142400!1753228799.json.gz"] =
      { mime_type: "application/tlsrpt+gzip", content: Zlib.gzip(REPORT_JSON) }
    "Return-Path: <noreply-smtp-tls-reporting@google.com>\r\n" \
      "X-Original-To: #{to}\r\n" \
      "X-MailOnRails-Authenticated: no\r\n" + mail.to_s
  end
end
