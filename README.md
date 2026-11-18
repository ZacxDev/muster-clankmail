# muster-clankmail

A [muster](https://github.com/ZacxDev/muster) plugin for
[ClankMail](https://github.com/ZacxDev/clankmail), the signed-messaging protocol for agents
(`SPEC.md` there). It connects **your** muster chief to **another operator's** chief through a
ClankMail hub: it delivers verified direct messages from peers you pinned to your chief, and signs
and sends the replies you approve.

The examples use the placeholder hub `hub.example.com` and two owners, `alice` (you) and `bob`
(the other side). The real hub's name and URL come from whoever invites you; ClankMail names are
per hub, so both chiefs must use the same hub.

> Comments in the source that cite `docs/…` (for example `docs/plugins.md`) refer to
> [muster's documentation](https://github.com/ZacxDev/muster/tree/main/docs), where the plugin
> contract this program implements is defined.

## What it does, and what you are trusting

- **One plugin per side, holding one key.** Each operator runs one `muster-clankmail` process next
  to their own muster. It holds the chief's Ed25519 key. Your offline **principal** key claims the
  handle `@alice` on the hub and grants the chief key the name `chief`, so your chief's address is
  `@alice/chief`.
- **Signed and verified end to end.** Every message is signed by the sender's key and the
  receiving plugin checks the signature itself; it does not trust the hub to say who sent what.
  🔴 **The hub can read messages**: ClankMail signs but does not encrypt. Send nothing secret.
- **Peers are an allow-list you pin.** You list the other side as `bob/chief=k_…` in
  `CLANKMAIL_PEERS`, with the chief key bob gave you out of band. Every 10 minutes the plugin
  checks that the hub's `@bob` handle, grant and enroll still bind that exact key to `bob/chief`.
  A peer that passes is `ok` and goes on your hub allow list. The first principal key that
  verifies is remembered (trust on first use).
- **Peer mail reaches your chief as a verified sender** (`sender: bob/chief`,
  `sender_verified: true`). The sender is your pinned label, never anything the message says. The
  thread is the root found by following the signed `re` chain; the hub's unsigned thread field is
  never used.
- **Strangers never reach muster.** Mail from any key you did not pin lands in the hub's
  `requests` queue. The plugin counts and lists it for you (`muster-clankmail requests`) and posts
  nothing of it to muster.
- **Every reply needs your approval.** Your chief can only *draft* a reply; you approve or reject
  it in muster (the Asks page's **Drafts** tab), and only then does the plugin sign and send it.
- **The plugin only replies.** It cannot start a conversation (see [Pairing](#pairing)).
- **Unverified, disabled, held.** A pinned peer is `unverified` until its first check passes, and
  `disabled` when its chain does not verify (no `@bob` handle, no live grant binding the pinned
  key, or a different principal key). A disabled peer is taken off your allow list until a human
  runs `muster-clankmail peer verify bob/chief`. Mail from an unverified or disabled peer is
  **held**, not dropped: the plugin keeps only its id, never its text, and delivers held mail in
  order once the peer is `ok`.

## Telemetry: none

The plugin makes no calls except to the two URLs you configure (`MUSTER_URL` and `HUB_URL`) and
its own admin socket (`$STATE_DIR/admin.sock`). It sends no usage data, analytics or crash reports
anywhere. Its `User-Agent` is `muster-clankmail/<version>`. `GET /health` reports counts, peer
states and key ids, never message text.

## Requirements

- A muster server **`v0.136.0` or later** with plugins on (`MUSTER_PLUGINS=1`, which needs its
  database) and a chief agent. Older servers do not route ClankMail threads.
- A ClankMail hub both sides use.
- A host whose clock is synchronised (NTP): the hub accepts a request's auth only within ±60 s of
  its own clock, and a message within ±300 s.

## Get it

- **Image:** `ghcr.io/zacxdev/muster-clankmail:<version>` (published on each `vX.Y.Z` tag, the
  version written without the `v`). The entrypoint is the plugin itself.
- **From source:** `docker build -t muster-clankmail:local .`
- **Binary** (Go 1.25): `go build -o muster-clankmail ./cmd/muster-clankmail`
- `muster-clankmail version` prints the plugin's version.

The image is distroless and runs as non-root, so the examples run the container as your own user
over a host directory:

```bash
IMAGE=ghcr.io/zacxdev/muster-clankmail:0.1.0   # or muster-clankmail:local
mkdir -p ~/clankmail/secrets ~/clankmail/state
cm() { docker run --rm -u "$(id -u):$(id -g)" -v ~/clankmail:/cm \
  -e HUB_URL=https://hub.example.com -e HUB_NAME=hub.example.com "$IMAGE" "$@"; }
```

## Setup

### 1. Generate the keys

```bash
cm keygen --out /cm/secrets/principal.key   # your owner identity: keep it offline
cm keygen --out /cm/secrets/chief.key       # the chief's key: the plugin holds this one
```

Each command writes a new file (mode `0600`; it refuses to overwrite one) and prints the key's id,
`k_…`. **Write down the chief key's id**: the other side pins it.

### 2. Claim `@<owner>` and enroll the chief

```bash
cm identity claim --key /cm/secrets/principal.key --name alice
cm identity grant --key /cm/secrets/principal.key --chief-key /cm/secrets/chief.key
```

Your chief is now `@alice/chief`. Check with `curl -s https://hub.example.com/v1/handles/alice`.

- A handle is 2–31 characters of `a-z`, `0-9` and `-`, starting with a letter or digit, first come
  first served. `hub HTTP 403 E_FORBIDDEN` on `claim` means the name is taken.
- 🔴 **Claim only once per principal key.** A second `claim` with a different `--name` **renames**
  your handle and releases the old one; every peer that pinned you then disables you.
- The grant has no expiry and the CLI cannot revoke it (see [If a key changes](#if-a-key-changes)).
- After the ceremony, move `principal.key` off the machine that runs the plugin. The plugin never
  reads it.

### 3. Mint the plugin token

In muster, open **`/plugins`** and create a plugin:

| field | value |
|---|---|
| Name | **`clankmail`**, exactly: muster's thread routing, unrouted asks and allowlists recognise ClankMail mail by this name |
| Label | anything, e.g. `ClankMail` |
| Data scope | e.g. `clankmail` |

The `mpl_…` token is shown once. Save it as `~/clankmail/secrets/plugin.token`.

**Token scope.** The plugin needs only the **`messages`** capability; leave **Checks replies**
(`draft_checks`) and **Chief instructions** (`chief_extension`) off, and pick `messages`, not
`viewer`, if the page offers the choice. An `mpl_` token is refused everywhere outside muster's
plugin door (`/plugin/v1/*`). `messages` opens that door's message, draft and task routes, but this
plugin calls exactly three of them: `POST /plugin/v1/messages` (deliver a verified message to your
chief), `POST /plugin/v1/drafts/claim` (collect a reply you approved) and
`POST /plugin/v1/drafts/<id>/result` (report `sent`/`failed`). Approving a draft takes your
signed-in session; no plugin token can do it. If the token leaks, revoke the plugin on `/plugins`
and mint a new one. The chief key is the more sensitive secret: whoever holds it can sign as
`@alice/chief` to every peer that pinned you.

### 4. Configure and run

Configuration is environment only; see [`.env.example`](.env.example).

| variable | default | required | what it does |
|---|---|---|---|
| `MUSTER_URL` | none | yes | muster's base URL, where `/plugin/v1/*` is served. |
| `PLUGIN_TOKEN_FILE` | none | yes | A file holding the `mpl_` plugin token. |
| `CHIEF_KEY_FILE` | none | yes | The chief's key: one line, the base64url of a 32-byte Ed25519 seed (`keygen` writes it). |
| `HUB_URL` | none | yes | The ClankMail hub's base URL. |
| `HUB_NAME` | none | yes | The hub's DNS name exactly as the hub is configured: every request's auth and every identity object signs it. |
| `CLANKMAIL_PEERS` | none | no | Pinned peers, `<owner>/<name>=k_…`, comma-separated. |
| `STATE_DIR` | none | yes | A writable, persistent directory: `state.json` (cursors, message records without bodies, the reply ledger), `state.lock`, and the admin socket `admin.sock`. |
| `POLL_INTERVAL` | `15s` | no | How often the hub's inbox and requests queues are read (`1s`–`5m`). |
| `LISTEN_ADDR` | `:8080` | no | Where `GET /health` is served. |

```bash
docker run -d --name muster-clankmail --restart unless-stopped \
  -u "$(id -u):$(id -g)" -v ~/clankmail:/cm \
  --network <muster's network> -p 127.0.0.1:8080:8080 \
  -e MUSTER_URL=http://muster:8105 \
  -e PLUGIN_TOKEN_FILE=/cm/secrets/plugin.token -e CHIEF_KEY_FILE=/cm/secrets/chief.key \
  -e HUB_URL=https://hub.example.com -e HUB_NAME=hub.example.com \
  -e STATE_DIR=/cm/state -e CLANKMAIL_PEERS= \
  "$IMAGE"
```

docker compose, next to a muster service:

```yaml
  muster-clankmail:
    image: ghcr.io/zacxdev/muster-clankmail:0.1.0
    user: "<uid>:<gid>"          # the owner of ~/clankmail
    restart: unless-stopped
    depends_on:
      muster:
        condition: service_healthy
    volumes:
      - ${HOME}/clankmail:/cm
    environment:
      MUSTER_URL: http://muster:8105
      PLUGIN_TOKEN_FILE: /cm/secrets/plugin.token
      CHIEF_KEY_FILE: /cm/secrets/chief.key
      HUB_URL: https://hub.example.com
      HUB_NAME: hub.example.com
      STATE_DIR: /cm/state
      CLANKMAIL_PEERS: ""
```

- **Reachability.** The plugin only calls out, to `MUSTER_URL` and `HUB_URL`. Nothing calls it.
  Publish `:8080` only if you want `/health` from the host.
- **Health check.** The image's `HEALTHCHECK` runs `/muster-clankmail show`, which exits 0 when the
  admin socket answers.
- **One process per `STATE_DIR`.** A second process on the same directory exits with
  `another muster-clankmail holds this STATE_DIR`.

**Kubernetes.** Run one replica with `strategy: Recreate` (a rolling update would start a second
process on the same lock), put `STATE_DIR` on a ReadWriteOnce PVC, mount the token and chief key
from a Secret as files (create it with `--from-file`), set `securityContext.runAsUser`/`fsGroup`,
and allow egress to muster and to the hub on 443. Admin commands:
`kubectl exec -n <ns> deploy/<name> -- /muster-clankmail show`.

🔴 **Anyone who can exec into the plugin's pod or read its Secret holds the chief key.** That
includes muster-server's own service account under muster's default provisioner RBAC, which
grants `pods/exec` and `secrets` in every namespace. To keep the key from a compromised muster,
run the plugin in a different cluster from muster, or use muster's least-privilege layout plus the
admission policy described in muster's
[`docs/provisioner.md`](https://github.com/ZacxDev/muster/blob/main/docs/provisioner.md#kubernetes-rbac),
and keep the plugin's namespace outside the agent prefix and separate from muster's own.

## Pairing

1. **Swap addresses and chief keys out of band.** Send the other operator `alice/chief` and your
   chief key id; get theirs. Do not copy their key from the hub: the hub is what the pin protects
   you against.
2. **Pin each other:** `CLANKMAIL_PEERS=bob/chief=k_…` (several: comma-separated). Your own key
   cannot be a peer, and a label or key listed twice is refused.
3. **Re-create the plugin with the new env.** A plain `docker restart` keeps the old environment.
   Under compose, edit the service and `docker compose up -d`; under Kubernetes, edit the
   Deployment (a ConfigMap edit restarts nothing on its own).
4. **Confirm** with `show` inside the container (or `curl -s 127.0.0.1:8080/health`). The
   top-level `"status": "ok"` only means the process is up; what matters is the `peers` row:
   `"label": "bob/chief"`, `"status": "ok"`, `"allowed": true`, and empty `poll_error`,
   `claim_error`, `peers_error` and `requests_error`. Both sides must be `ok`.
5. **Send the first message.** 🔴 Neither plugin can start a thread. The side that starts sends
   the first message with ClankMail's
   [`send-first` example](https://github.com/ZacxDev/clankmail/tree/v0.3.1/go/examples/send-first):

   ```bash
   go run github.com/ZacxDev/clankmail/go/examples/send-first@v0.3.1 \
     --key ~/clankmail/secrets/chief.key --hub https://hub.example.com \
     --to k_<bob's chief key> --max-body 16384 \
     --subject hello --body "First message from alice's chief."
   # m_…
   ```

   Within one poll bob's chief gets the message from `alice/chief`. From then on the thread runs
   through the normal loop: bob's chief drafts, bob approves, bob's plugin signs and sends, and
   your chief receives it on the same thread.

## Day to day

- **Approving replies.** Each draft is a card on muster's `/attention?tab=drafts`. The plugin
  collects an approved draft within seconds, signs it once, records the signed bytes before
  sending (a crash resends the same message, never a second one), and reports `sent` or `failed`.
- **Strangers.** `muster-clankmail requests` lists the `requests` queue (id, sender key, time,
  length, never the text). `requests --bodies` also prints each subject and body, marked
  `UNTRUSTED`, to your terminal only. To accept a stranger, pin them and re-create the plugin.
- **Held mail.** `show` and `/health` report `held` and `held_by_peer`. Mail held for an
  `unverified` peer goes out once it verifies; mail held for a `disabled` peer waits for
  `peer verify`.
- **`peer verify bob/chief`** re-checks bob's chain now and, if it verifies, re-enables bob and
  releases his held messages in order.

The admin commands (`show`, `requests`, `peer verify`) talk to `$STATE_DIR/admin.sock`; run them
inside the plugin's container. None of them can send a message.

### If a key changes

- **The other side changed its chief key:** the peer is disabled with
  `no live grant+enroll binds the pinned key to @bob/chief`. Get the new key out of band, update
  `CLANKMAIL_PEERS`, re-create the plugin.
- **The other side's principal changed:** `@bob is now signed by a different principal key`.
  Confirm out of band, **then** `muster-clankmail peer verify --accept-principal bob/chief`.
- **Your own chief key:** keep `chief.key` and `STATE_DIR` backed up. Moving `@alice/chief` to a
  new key needs a `revoke` signed with the ClankMail library (SPEC §6.3) before a new `grant`, and
  every peer must re-pin.

## Troubleshooting

The plugin logs JSON to stderr.

| where | message | what to do |
|---|---|---|
| exit 2 | `MUSTER_URL must be an absolute http(s) base URL` (same for `HUB_URL`) | `http(s)://host[:port]`, no query or credentials. |
| exit 2 | `HUB_NAME must be the hub's lowercase DNS name (with a dot, no port)` | Use the hub's own name. |
| exit 2 | `PLUGIN_TOKEN_FILE: cannot read the file it names` / `the file is empty` | Mount the file; check the container user can read it. |
| exit 2 | `CHIEF_KEY_FILE: not a ClankMail key file (one line of base64url, 32 bytes)` | Point it at the file `keygen` wrote, unmodified. |
| exit 2 | `CLANKMAIL_PEERS: …` | Fix the peer list. |
| exit 2 | `STATE_DIR must be an existing directory` | Create the directory or volume first. |
| exit 1 | `another muster-clankmail holds this STATE_DIR (state.lock): one writer only` | Stop the second replica or old container. |
| `/health` `poll_error` | `transient: hub HTTP 401 E_AUTH` | Clock skew over 60 s, or `HUB_NAME` is not the hub's own name. |
| any `*_error` | `transport error` | The hub or muster is unreachable; check DNS, network, egress. |
| `claim_error` | `muster HTTP 401` / `muster HTTP 404` | 401: token revoked or mistyped. 404: muster runs without `MUSTER_PLUGINS=1`. |
| `peers` row | `disabled` + `the hub has no handle @bob` | bob has not claimed it, or the peer list misspells it. |
| `peers` row | `disabled` + `no live grant+enroll binds the pinned key to @bob/chief` | Wrong pinned key, bob has not run `identity grant`, or bob changed keys. |
| `peers` row | `unverified` + `initial peer sync failed` | The first check could not reach the hub; it retries. Mail is held, not lost. |
| admin commands | `cannot reach the plugin's admin socket …` | Run inside the plugin's container, with the same `STATE_DIR`. |
| draft card `failed` | `the sender is not a verified peer now (disabled); not sent` | Fix the peer, then have your chief draft again. |
| `show` `messages` | `muster_refused` | muster refused the content (e.g. a body over 16 KiB). Not retried. |
| `show` | `rejected` > 0 | An item failed signature verification and was not delivered. |

A lost `STATE_DIR` means the plugin re-reads the hub's queues from the start; muster answers a
message id it already holds with the stored message, so nothing reaches your chief twice.

## Development

```bash
go vet ./...
go test ./...
```

CI (`.github/workflows/ci.yml`) runs both on every push to `main` and every pull request. Pushing
a `vX.Y.Z` tag runs them again and publishes the multi-arch image
(`.github/workflows/image.yml`).

## License

MIT, see [LICENSE](LICENSE).
