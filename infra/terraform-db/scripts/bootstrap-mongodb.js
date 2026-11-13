// Run after the official image has initialized the root user and restarted with --replSet.
// Safe to rerun on an existing disk: never drop data or reset existing credentials.
const host = process.env.MONGO_HOST;
let admin;
let lastError;
for (let attempt = 0; attempt < 120; attempt++) {
  try {
    admin = new Mongo(`mongodb://${host}/?directConnection=true&serverSelectionTimeoutMS=2000`).getDB("admin");
    if (!admin.auth(process.env.MONGO_INITDB_ROOT_USERNAME, process.env.MONGO_INITDB_ROOT_PASSWORD)) {
      throw new Error("Root authentication failed; preserve the original Terraform state and credentials.");
    }
    // mongosh versions can either return a failed command or throw its error.
    let status;
    try {
      status = admin.runCommand({ replSetGetStatus: 1 });
    } catch (error) {
      if (error.code !== 94) throw error;
      status = { code: 94 };
    }
    if (status.code === 94) {
      const result = admin.runCommand({
        replSetInitiate: { _id: "rs0", members: [{ _id: 0, host }] },
      });
      if (result.ok !== 1) throw new Error(`Replica set initialization failed: ${result.codeName}`);
    } else if (status.ok !== 1 || status.set !== "rs0") {
      throw new Error(`Unexpected replica set state: ${status.codeName || status.set}`);
    }
    if (admin.runCommand({ hello: 1 }).isWritablePrimary) break;
  } catch (error) {
    lastError = error;
  }
  sleep(2000);
}
if (!admin || !admin.runCommand({ hello: 1 }).isWritablePrimary) {
  throw lastError || new Error("MongoDB did not become primary within the startup deadline.");
}

const applicationDB = admin.getSiblingDB("mongo_bench");
if (!applicationDB.getUser("mongo-bench")) {
  applicationDB.createUser({
    user: "mongo-bench",
    pwd: process.env.MONGO_APP_PASSWORD,
    roles: [{ role: "readWrite", db: "mongo_bench" }],
  });
}
const verificationDB = new Mongo(`mongodb://${host}/?directConnection=true`).getDB("mongo_bench");
if (!verificationDB.auth("mongo-bench", process.env.MONGO_APP_PASSWORD)) {
  throw new Error("Application authentication failed; restore the original credentials instead of replacing the data.");
}
print("MongoDB rs0 is primary and the application user is ready.");
