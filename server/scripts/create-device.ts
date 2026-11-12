import { config } from '../src/config.ts';
import { randomToken, sha256 } from '../src/crypto.ts';
import { openDb } from '../src/db.ts';

// Dev pairing: a session for the Debug "Developer pairing" sheet. It prints a refresh token; the app trades it for an access token.
// usage: npm run device -- [user_id] [label]   (omit user_id to create a new user)
const [userArg, label] = process.argv.slice(2);
const db = openDb(config.dbPath);
const userId = userArg || db.createUser();
const token = randomToken('prt');
db.addRefreshToken(db.createSession(userId, label ?? 'dev'), sha256(token), Date.now() + config.auth.refreshTtlMs);
console.log(JSON.stringify({ user_id: userId, refresh_token: token }));
