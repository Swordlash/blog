-- Asking for a passkey or the password each time an encrypted space is
-- opened (#213, Wiki.Core.Space's Entry): set by the space's
-- administrators, for the space and every space under it. The server only
-- keeps the setting; the reader's browser asks before it decrypts anything
-- of the space. False for every space until an administrator sets it.
ALTER TABLE spaces ADD COLUMN confirm_entry BOOLEAN NOT NULL DEFAULT FALSE;
