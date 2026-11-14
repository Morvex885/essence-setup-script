//! Node paths Essence manages. The renderer writes only these; the model
//! accepts only these as `applied.files` keys (they become `remove.list`
//! entries the executor deletes as root).

use crate::validation::domain_valid;

pub const MIHOMO_CONFIG_PATH: &str = "/etc/mihomo/config.yaml";
pub const MIHOMO_SERVICE_PATH: &str = "/etc/systemd/system/mihomo.service";
pub const SYSCTL_PATH: &str = "/etc/sysctl.d/99-vpn-speedup.conf";
pub const STREAM_PATH: &str = "/etc/nginx/modules-enabled/90-essence-stream.conf";
pub const SITES_AVAILABLE: &str = "/etc/nginx/sites-available/";
pub const SITES_ENABLED: &str = "/etc/nginx/sites-enabled/";
pub const AWG_CONF_PATH: &str = "/etc/amnezia/amneziawg/awg0.conf";

/// Subscription host files (`setup_subscription` of `subscription.sh`).
pub const SUB_SITE: &str = "essence-sub";
pub const SUB_LIMIT_PATH: &str = "/etc/nginx/conf.d/essence-sub-limit.conf";
pub const SUB_CLEANUP_PATH: &str = "/usr/local/bin/essence-sub-cleanup";
pub const SUB_CLEANUP_SERVICE_PATH: &str = "/etc/systemd/system/essence-sub-cleanup.service";
pub const SUB_CLEANUP_TIMER_PATH: &str = "/etc/systemd/system/essence-sub-cleanup.timer";
const SUB_MARKER: &str = ".essence-sub";

/// Empty marker in the subscription webroot: the applied file set names the
/// hostname whose certificate goes when the host moves.
pub fn sub_marker(hostname: &str) -> String {
    format!("/var/www/{hostname}/{SUB_MARKER}")
}

/// The hostname of a subscription webroot marker path.
pub fn sub_marker_host(path: &str) -> Option<&str> {
    path.strip_prefix("/var/www/")?.strip_suffix(SUB_MARKER)?.strip_suffix('/').filter(|host| domain_valid(host))
}

/// A path the renderer can record in `applied.files`.
pub fn managed_file(path: &str) -> bool {
    matches!(path, MIHOMO_CONFIG_PATH | MIHOMO_SERVICE_PATH | SYSCTL_PATH | STREAM_PATH | AWG_CONF_PATH | SUB_LIMIT_PATH
        | SUB_CLEANUP_PATH | SUB_CLEANUP_SERVICE_PATH | SUB_CLEANUP_TIMER_PATH)
        || path.strip_prefix(SITES_AVAILABLE).is_some_and(|site| site == SUB_SITE || domain_valid(site))
        || sub_marker_host(path).is_some()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn only_rendered_paths_are_managed() {
        for path in [MIHOMO_CONFIG_PATH, MIHOMO_SERVICE_PATH, SYSCTL_PATH, STREAM_PATH, AWG_CONF_PATH, SUB_LIMIT_PATH,
            SUB_CLEANUP_PATH, SUB_CLEANUP_SERVICE_PATH, SUB_CLEANUP_TIMER_PATH, "/etc/nginx/sites-available/essence-sub",
            "/var/www/sub.example.com/.essence-sub", "/etc/nginx/sites-available/de.example.com"] {
            assert!(managed_file(path), "{path}");
        }
        for path in ["/", "/etc", "/root/.ssh", "/etc/mihomo", "/etc/nginx/sites-available/../../../home",
            "/etc/nginx/sites-available/a b", "/etc/nginx/sites-available/", "/etc/nginx/sites-enabled/de.example.com",
            "/etc/mihomo/config.yaml\n/etc", "/var/www/../.essence-sub", "/var/www/a/b/.essence-sub", "/var/www/x.essence-sub"] {
            assert!(!managed_file(path), "{path:?}");
        }
    }
}
