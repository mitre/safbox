<!--
Draft comment for mitre/heimdall2#4145 (https://github.com/mitre/heimdall2/issues/4145),
prepared under safbox-m5f.29. The owner posts it; once posted, its URL goes into
the FIPS notes in docs/reference/services.md. Everything below this comment is the text to paste.
-->

Reproduction of the bcrypt item on 2.14.0, and a request to revive #4850:

**bcryptjs password and API-key hashing is outside the FIPS boundary, reproduced on Heimdall 2.14.0 under host FIPS enforcement**

We run Heimdall in an appliance that is FIPS-enforcing end to end, and we reproduced the bcrypt part of #4145 on the current release. The container is otherwise in good shape for FIPS. Node's crypto runs on the image's OpenSSL FIPS provider, and MD5 is refused. Local passwords and API keys, however, are still hashed by bcryptjs, which never reaches that provider.

**Environment**
- Heimdall 2.14.0, image `mitre/heimdall2@sha256:06f6e72d416a71e8939da341f78681891aa531765a9d4c62dcc224d3044d0347`, run with podman
- Host: Rocky Linux 10.2 installed with `fips=1`; `/proc/sys/crypto/fips_enabled` = 1; `update-crypto-policies --show` = FIPS
- Container: Red Hat Enterprise Linux 9.8, Node v22.23.1, OpenSSL 3.5.5 with the "Red Hat Enterprise Linux 9 - OpenSSL FIPS Provider" active
- Inside the container: `node -p "require('crypto').getFips()"` returns `1`; `crypto.createHash('md5')` throws `ERR_OSSL_EVP_UNSUPPORTED`
- bcryptjs 3.0.3 (`apps/backend/node_modules/bcryptjs`)

**Observed**
- The seeded administrator's `Users."encryptedPassword"` begins `$2b$14$` (prefix only shown).
- After creating one API key through `POST /apikeys`, `ApiKeys."apiKey"` begins `$2b$14$`. The key then authenticates (`Authorization: Api-Key ...`), so the compare path is bcrypt too.

**Source locations** (identical at v2.14.0 = abf4030218818f723a40b962c360acb03cc72789 and master = d9cfbf9485a8183877119bc9ebdf01c13967c83b, 2026-10-16)
- `apps/backend/package.json:54`: `"bcryptjs": "^3.0.0"`
- Hash: `apps/backend/src/users/users.service.ts:66`, `:89` (`hash(password, 14)` on create and update); `apps/backend/src/apikeys/apikey.service.ts:43` (`hash(JWTSignature, 14)`); `apps/backend/seeders/20200514154327-create-administrator.js:56` (`bcrypt.hashSync(password, 14)`)
- Compare: `apps/backend/src/authn/authn.service.ts:53` (local login), `:75` (API key), `:208` (`testPassword`); `apps/backend/src/users/users.service.ts:126`
- Storage: `Users."encryptedPassword"`; `ApiKeys."apiKey"` (`apps/backend/migrations/20210615141642-add_api_token.js:24`)

**Why this is outside the FIPS boundary**
1. bcrypt (EksBlowfish) is not an approved algorithm. The approved password-based KDF is PBKDF2 with an approved HMAC (NIST SP 800-132), and bcrypt is not among the approved security functions (SP 800-140C).
2. bcryptjs is pure JavaScript. Its Blowfish rounds run in JS and never call Node's `crypto`, so no OpenSSL provider, FIPS or not, is involved, whatever the host enforces. Only the salt comes from `crypto.getRandomValues`/`randomBytes`, and with it the provider's DRBG. Switching to native `bcrypt` would not help: it is still bcrypt.

**FIPS-approved alternative via Node's crypto**
- Passwords: PBKDF2-HMAC-SHA-256 through `crypto.pbkdf2` (SP 800-132), as #4850's `libs/common/crypto/crypto.ts` does: a salt of at least 128 bits from a CSPRNG such as `crypto.randomBytes` (#4850 draws 32 bytes through its own `randomBytes` wrapper over `getRandomValues`), an iteration count well above the SP 800-132 floor (#4850 uses 600,000, OWASP's current figure for PBKDF2-HMAC-SHA256), and a derived key of at least 112 bits. Under OpenSSL's FIPS provider this is PBKDF2 @ fips. We confirmed `pbkdf2Sync(..., 600000, 32, 'sha256')` runs inside the 2.14.0 container in FIPS mode.
- scrypt is not an option. It is not a FIPS-approved KDF, the RHEL 9 FIPS provider in the image offers no SCRYPT (`openssl list -kdf-algorithms` lists PBKDF2, HKDF, KBKDF, SSKDF, SSHKDF, TLS1-PRF, TLS13-KDF and X942/X963 KDFs @ fips), and `crypto.scryptSync` throws inside the container. Argon2 is not approved either.
- API keys: the stored value is a hash of the JWT signature, a 256-bit HMAC-SHA-256 output under `API_KEY_SECRET`, unpredictable as long as that secret is, and looked up by `keyId`. A slow password KDF is not needed for a secret like that; SHA-256 or HMAC-SHA-256 through `crypto` would be approved and cheaper per request. Reusing the PBKDF2 helper, as #4850 does, is also approved.

**Migration of existing `$2` hashes** (every existing deployment has at least the seeded admin)
- Decide per stored value, not with a global switch. In #4850 the flag `USE_NEW_ENCRYPTION_STRATEGY` chooses the algorithm for every compare. Once it is set, any existing `$2b$...` hash would be parsed as a hex salt plus digest, and every bcrypt-hashed user, including the admin, plus every API key would fail to authenticate. Dispatching on the stored prefix lets both formats coexist during migration: `$2` means bcrypt, the new format means PBKDF2.
- Store a self-describing format, e.g. the PHC string `$pbkdf2-sha256$i=600000$<salt>$<hash>`, rather than bare hex. Then the algorithm and iteration count can be detected and raised later without another flag day.
- Passwords: verify with bcrypt, then rehash with PBKDF2 on the next successful login (local login and `testPassword`). Users who never log in keep a `$2` hash until an admin forces a reset. A strict FIPS mode (bcrypt verification disabled) could then reject the rest and require a password reset.
- API keys: the plaintext is never stored, so a key can only be rehashed when it is presented. Either rehash on its next successful use, or document that existing keys must be reissued.
- Seeded admin: the seeder (`create-administrator.js:56`) should use the new hash, so a fresh install has no bcrypt hash at all.
- Smaller points on #4850's helper: compare with `crypto.timingSafeEqual` rather than `===`, and use async `crypto.pbkdf2` rather than `pbkdf2Sync`. 600,000 iterations on the event loop blocks every other request for the duration of each login.

We can retest a branch or release candidate in the same FIPS-enforcing environment and report back.
