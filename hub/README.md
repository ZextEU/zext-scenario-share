# Running your own Scenario Hub

The hub turns long scenario codes into short ones (`ZX-4F9K2QH`). Zext runs a free community hub that the add-on uses by default, so **you only need this if you want your own**: for a private group of servers, or to stay independent of the community hub.

It's one small Cloudflare Worker with a D1 database, and Cloudflare's free plan covers it easily.

## What you need

- A free Cloudflare account: https://dash.cloudflare.com/sign-up
- Node.js 18 or newer: https://nodejs.org (it comes with `npx`)

## Set it up

Open a terminal in this `hub` folder and run each step.

**1. Log in to Cloudflare.** A browser window opens. Click **Allow**.
```bash
npx wrangler@4.20.0 login
```

**2. Make your config file.** Copy `wrangler.example.toml` to `wrangler.toml`. You can rename `name` (the hub's name in its web address) if you like.

**3. Create the database.**
```bash
npx wrangler@4.20.0 d1 create zext-scenario-hub
```
It prints a `database_id`. Paste it into `wrangler.toml`, replacing `REPLACE_WITH_DATABASE_ID`.

**4. Create the table.**
```bash
npx wrangler@4.20.0 d1 execute zext-scenario-hub --remote --file schema.sql
```
Answer **yes** if it asks.

**5. Put it online.**
```bash
npx wrangler@4.20.0 deploy
```
The first time, it asks to register a `workers.dev` subdomain. Answer **Y** and pick a name. It prints your hub's address, for example `https://zext-scenario-hub.yourname.workers.dev`.

> A brand-new subdomain can take 5–20 minutes before it answers. Until then, visiting it gives a security or handshake error. That's normal, so just wait.

**6. Set two secrets.** Each command asks you to type a value.
```bash
npx wrangler@4.20.0 secret put IP_SALT
npx wrangler@4.20.0 secret put ADMIN_TOKEN
```
- `IP_SALT`: any long random text. It scrambles the fingerprints used for the upload limit. You never need it again.
- `ADMIN_TOKEN`: a long random password. **Save it** (in a password manager), because you need it to take codes down.

**7. Point your servers at it.** In `whip_core/html/js/wp/director.js` (after installing the add-on), set:
```js
const HUB_URL = 'https://zext-scenario-hub.yourname.workers.dev';
```
Use no slash at the end, then `restart whip_core`. Every server that should share short codes with yours needs the same address.

**Check it:** open your hub's address in a browser. It should say *Zext Scenario Hub: short codes for WHIP Director scenarios.*

## Looking after it

**Take a code down** (spam or abuse):
```bash
curl -X DELETE -H "Authorization: Bearer YOUR_ADMIN_TOKEN" https://your-hub-address/v1/codes/ZX-XXXXXXX
```

**See what's stored:**
```bash
npx wrangler@4.20.0 d1 execute zext-scenario-hub --remote --command "SELECT id, name, cards, things, datetime(created_at/1000,'unixepoch') AS created FROM codes ORDER BY created_at DESC LIMIT 50"
```

**Change the upload limit:** edit `UPLOADS_PER_HOUR` near the top of `src/index.js` (20 by default), then `npx wrangler@4.20.0 deploy` again.

**Update the hub** after pulling a newer version of this repository: run `npx wrangler@4.20.0 deploy` again. Stored codes are kept.

## Free plan limits

Workers: 100,000 requests a day. D1: 5 GB of storage, 5 million rows read and 100,000 rows written a day. One upload is one write and one lookup is one read, and a code is usually 2–30 KB, so this covers many thousands of scenarios.

## Testing it on your own computer

```bash
npm install
cp wrangler.example.toml wrangler.toml     # any placeholder database_id works locally
npm run db:local
npx wrangler dev --local
```
The hub then answers at http://localhost:8787.

## What it stores

For each code, the hub stores:
- the long code
- its name and description
- how many cards and placed things it has
- when it was uploaded
- a SHA-256 hash of the long code, so duplicates get the same short code
- a SHA-256 hash of the uploader's address plus `IP_SALT`, for the hourly limit

It never stores addresses themselves.
