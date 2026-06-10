# Sync diagnostics configuration -- EXAMPLE / template.
# Copy this file to  scripts\sync.config.ps1  (which is gitignored) and fill in YOUR real values.
# NEVER put real credentials in this example file or commit sync.config.ps1.
$SyncConfig = @{
	CouchUrl     = 'http://127.0.0.1:5984'                  # CouchDB on the master (WSL localhost forwarding)
	TailscaleUrl = 'https://YOUR-HOST.YOUR-TAILNET.ts.net'  # Tailscale Serve URL remote devices use
	CouchUser    = 'obsidian'
	CouchPass    = 'CHANGE_ME'                              # your CouchDB password
	DbName       = 'obsidian-vault'
	VaultDir     = 'C:\path\to\your\vault'                  # the master laptop's vault folder
	Devices      = @(
		@{ name='phone';  ip='100.x.x.x'; vault='/storage/emulated/0/Documents/YourVault' }
		@{ name='tablet'; ip='100.y.y.y'; vault='/storage/emulated/0/YourVault' }
	)
}
