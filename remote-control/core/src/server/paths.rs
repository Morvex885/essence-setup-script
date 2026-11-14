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

/// A path the renderer can record in `applied.files`.
pub fn managed_file(path: &str) -> bool {
    matches!(path, MIHOMO_CONFIG_PATH | MIHOMO_SERVICE_PATH | SYSCTL_PATH | STREAM_PATH)
        || path.strip_prefix(SITES_AVAILABLE).is_some_and(domain_valid)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn only_rendered_paths_are_managed() {
        for path in [MIHOMO_CONFIG_PATH, MIHOMO_SERVICE_PATH, SYSCTL_PATH, STREAM_PATH, "/etc/nginx/sites-available/de.example.com"] {
            assert!(managed_file(path), "{path}");
        }
        for path in ["/", "/etc", "/root/.ssh", "/etc/mihomo", "/etc/nginx/sites-available/../../../home",
            "/etc/nginx/sites-available/a b", "/etc/nginx/sites-available/", "/etc/nginx/sites-enabled/de.example.com",
            "/etc/mihomo/config.yaml\n/etc"] {
            assert!(!managed_file(path), "{path:?}");
        }
    }
}
