import { config } from '../src/config.ts';
import { randomToken, sha256 } from '../src/crypto.ts';
import { openDb } from '../src/db.ts';

// usage: npm run device -- [user_id] [label]   (omit user_id to create a new user)
const [userArg, label] = process.argv.slice(2);
const db = openDb(config.dbPath);
const userId = userArg || db.createUser();
const token = randomToken('pkd');
db.addDevice(userId, sha256(token), label ?? null);
console.log(JSON.stringify({ user_id: userId, device_token: token }));
