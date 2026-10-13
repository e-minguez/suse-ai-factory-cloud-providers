# SSH keys

Every cluster needs at least one SSH public key in `ssh_authorized_keys`. It is
installed for `node_username` on every node (and for root when
`permit_root_ssh` is set). The jumphost accepts keys only, and
`scripts/ssh.sh`, `scripts/kubeconfig.sh` and `scripts/build-logs.sh` connect
through it, so you need the matching private key on the machine that runs them.

The deployment does not generate keys for you: a key pair is a credential you
own and keep, not something Terraform state should hold. If you already have a
key (`~/.ssh/id_ed25519.pub` or `~/.ssh/id_rsa.pub`), use it and skip to
[Use the key](#use-the-key). The [web UI](webui.md#ssh-keys) can generate a
pair for you.

## Create a key

Use ed25519. Set a passphrase: it encrypts the private key on disk, and the SSH
agent means you type it once per session.

### Linux and macOS

```bash
ssh-keygen -t ed25519 -C "you@example.com"
```

Accept the default path (`~/.ssh/id_ed25519`) unless you want a dedicated key,
for example `-f ~/.ssh/aif_ed25519`. This writes the private key
`~/.ssh/id_ed25519` and the public key `~/.ssh/id_ed25519.pub`.

### Windows

The scripts in this repo are bash: run them from WSL (Windows Subsystem for
Linux) and follow the Linux steps inside WSL. The key then lives in the WSL
home (`~/.ssh`), not in the Windows profile.

To create a key with the OpenSSH client built into Windows 10 and 11
(PowerShell), for example for the web UI or another SSH client:

```powershell
ssh-keygen -t ed25519 -C "you@example.com"
```

The key is written to `C:\Users\<you>\.ssh\id_ed25519` and `id_ed25519.pub`.
If `ssh-keygen` is not found, install the optional feature *OpenSSH Client*
(Settings → System → Optional features).

## Protect the key

The private key (`id_ed25519`, no extension) grants access to every cluster that
lists its public key. Never share it, paste it into a tfvars file or commit it.
Only the `.pub` file goes into `ssh_authorized_keys`.

### Linux, macOS and WSL

```bash
chmod 700 ~/.ssh
chmod 600 ~/.ssh/id_ed25519          # private key: owner only
chmod 644 ~/.ssh/id_ed25519.pub      # public key
chmod 600 ~/.ssh/config              # if present
```

`ssh` refuses a private key that other users can read ("UNPROTECTED PRIVATE KEY
FILE"). In WSL, keep keys in the Linux home, not under `/mnt/c/`: Windows
drives mounted there do not keep Unix permissions by default.

### Windows

`ssh-keygen` creates the file readable by your user only. If `ssh` reports bad
permissions, for example after copying the file, reset the ACL to your user
alone:

```powershell
icacls $env:USERPROFILE\.ssh\id_ed25519 /inheritance:r /grant:r "${env:USERNAME}:F"
```

### Passphrase and agent

To add or change a passphrase on an existing key:

```bash
ssh-keygen -p -f ~/.ssh/id_ed25519
```

Load the key into the agent so the scripts can use it without prompting:

```bash
eval "$(ssh-agent -s)"              # Linux and WSL, if no agent is running
ssh-add ~/.ssh/id_ed25519           # macOS: ssh-add --apple-use-keychain ~/.ssh/id_ed25519
ssh-add -l                          # list loaded keys
```

On Windows, enable the agent once from an elevated PowerShell, then add the key:

```powershell
Get-Service ssh-agent | Set-Service -StartupType Automatic
Start-Service ssh-agent
ssh-add $env:USERPROFILE\.ssh\id_ed25519
```

## Use the key

Put the **public** key into `common-all.tfvars` (or a per-cluster
`terraform.tfvars`):

```bash
cat ~/.ssh/id_ed25519.pub
```

```hcl
ssh_authorized_keys = ["ssh-ed25519 AAAAC3Nza... you@example.com"]
```

Several keys can be listed, for example one per operator. Keys are part of the
image and of the node `user_data`: changing them rebuilds the image and
replaces all nodes.

The scripts use the standard `ssh` key lookup: keys loaded in the agent, then
the default files (`~/.ssh/id_ed25519`, `~/.ssh/id_rsa`, ...). A key with a
non-default name must be loaded in the agent (`ssh-add ~/.ssh/aif_ed25519`).

## Lost or leaked key

Remove the public key from `ssh_authorized_keys`, add a new one and run
`./deploy.sh`. This rebuilds the image and replaces the nodes, so plan it like
any other node replacement.
