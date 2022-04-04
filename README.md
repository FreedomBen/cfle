# cfle - CloudFlare Let's Encrypt

This script (which is built into a container image that can be run with a k8s `CronJob`)
will use Let's Encrypt to get a TLS certificate for the specified hostname(s) using
DNS challenge (`dns-01`).  It will then put that TLS certificate into the specified
K8s `Secret` where another application can use it.  If there is already a valid TLS
cert in the Secret that is not within the specified window of expiration, the script
will exit without making any changes.  This makes it safe to schedule the script often,
such as every day.  If a Slack API token is included, you can get notifications and
error messages automatically pushed to a Slack channel.

Stated another way, cfle will:

1.  Check to see if the specified TLS cert (in a k8s Secret) is expiring soon (within the specified interval)
1.  If not due, cfle will exit.  If ready for renewal, cfle will run certbot to renew the certificate
1.  cfle will put the new TLS cert into the specified k8s secret
1.  If provided a Slack API token, cfle will notify you of the happenings via the specified Slack channel(s)

For an example configuration, see the yaml files in the `k8s` directory.
