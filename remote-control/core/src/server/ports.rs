//! Internal node ports. No dependencies: the model validates profiles against
//! them and the renderer places services on them.

/// nginx site behind Reality self-steal (name-based vhosts).
pub const SITE_PORT: u16 = 8443;
/// mihomo Reality listener behind the nginx stream front.
pub const REALITY_INNER_PORT: u16 = 8444;
/// Subscription vhost behind the nginx stream front.
pub const SUB_INNER_PORT: u16 = 8445;
/// Telegram Proxy behind the nginx stream front.
pub const TG_INNER_PORT: u16 = 8446;
/// mihomo xHTTP listener behind nginx.
pub const XHTTP_NGINX_PORT: u16 = 8447;

/// Ports profiles may not use: the internal ones and local services.
pub const RESERVED_PORTS: [u16; 11] = [
    SITE_PORT, REALITY_INNER_PORT, SUB_INNER_PORT, TG_INNER_PORT, XHTTP_NGINX_PORT,
    9090, 1053, 2398, 8080, 8081, 8888,
];
