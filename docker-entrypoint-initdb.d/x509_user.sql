CREATE USER 'x509'@'%' REQUIRE X509;
GRANT ALL PRIVILEGES ON test.* TO 'x509'@'%';
