-- Passwords through OPAQUE (WP5.74a of docs/PLAN.md, the opaque package):
-- a user's registration record (opaque_record, the record's bytes in
-- unpadded base64url) and the Argon2id the browser stretched the password
-- with when it made the record (opaque_stretch, "t=<passes>,m=<bytes>"),
-- which a sign-in tells the browser. Both are NULL for a user who has no
-- record. The argon2id hash of password_hash is kept for an account from
-- before OPAQUE until its next sign-in, when the browser registers a
-- record and the hash is cleared; a user never has both.
ALTER TABLE users ADD COLUMN opaque_record TEXT NULL;
ALTER TABLE users ADD COLUMN opaque_stretch TEXT NULL;
