CREATE TABLE IF NOT EXISTS `users` (
  `id` int NOT NULL AUTO_INCREMENT PRIMARY KEY,
  `login` varchar(255) NOT NULL UNIQUE,
  `password_hash` varchar(255) NOT NULL,
  `salt` varchar(255) NOT NULL,
  UNIQUE KEY `idx_login` (`login`)
) DEFAULT CHARSET=utf8 ENGINE=MEMORY;

CREATE TABLE IF NOT EXISTS `login_log` (
  `id` bigint NOT NULL AUTO_INCREMENT PRIMARY KEY,
  `created_at` datetime NOT NULL,
  `user_id` int,
  `login` varchar(255) NOT NULL,
  `ip` varchar(255) NOT NULL,
  `succeeded` tinyint NOT NULL,
  KEY `idx_ip` (`ip`),
  KEY `idx_user_id` (`user_id`),
  KEY `idx_user_id_succeeded` (`user_id`,`succeeded`),
  KEY `idx_succeeded` (`succeeded`)
) DEFAULT CHARSET=utf8 ENGINE=MEMORY;
