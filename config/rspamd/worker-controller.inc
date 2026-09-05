# Controller worker (port 11334: the admin/learn API). Mounted by Kamal at
# /etc/rspamd/local.d/worker-controller.inc (see deploy.yml).
#
# Replaces the image's well-known default password ("q1"). The value comes
# from the accessory's RSPAMD_PASSWORD secret: the image exposes RSPAMD_*
# environment variables to its config templates with the prefix stripped.
# Plain text is accepted; the app sends the same secret verbatim as
# SMTP_RSPAMD_PASSWORD. enable_password gates the privileged commands
# (/learnspam, /learnham); password the read-only ones.
password = "{= env.PASSWORD =}";
enable_password = "{= env.PASSWORD =}";
