const assert = require("node:assert/strict");
const { readFileSync } = require("node:fs");
const { join } = require("node:path");
const { test } = require("node:test");
const { runInNewContext } = require("node:vm");

const source = readFileSync(join(__dirname, "../scripts/bootstrap-mongodb.js"), "utf8");

function bootstrap({ initialized = false, existingUser = false, throwNotInitialized = false, failFirstConnection = false, appAuth = true } = {}) {
  const state = { initialized, existingUser, initiations: 0, creations: 0, sleeps: 0, connections: 0 };
  const appDB = {
    getUser: () => state.existingUser ? { user: "mongo-bench" } : null,
    createUser: (user) => {
      assert.equal(user.user, "mongo-bench");
      assert.equal(user.roles.length, 1);
      assert.equal(user.roles[0].role, "readWrite");
      assert.equal(user.roles[0].db, "mongo_bench");
      state.existingUser = true;
      state.creations++;
    },
    auth: () => appAuth,
  };
  const admin = {
    auth: () => true,
    getSiblingDB: (name) => { assert.equal(name, "mongo_bench"); return appDB; },
    runCommand: (command) => {
      if (command.replSetGetStatus) {
        if (state.initialized) return { ok: 1, set: "rs0" };
        if (throwNotInitialized) throw Object.assign(new Error("NotYetInitialized"), { code: 94 });
        return { ok: 0, code: 94 };
      }
      if (command.replSetInitiate) {
        assert.equal(command.replSetInitiate._id, "rs0");
        assert.equal(command.replSetInitiate.members[0].host, "mongodb-0.mongodb.mongo-bench-db-dev.svc.cluster.local:27017");
        state.initialized = true;
        state.initiations++;
        return { ok: 1 };
      }
      if (command.hello) return { isWritablePrimary: state.initialized };
      throw new Error("Unexpected command");
    },
  };
  function Mongo() {
    state.connections++;
    if (failFirstConnection && state.connections === 1) throw new Error("Startup in progress");
    this.getDB = (name) => name === "admin" ? admin : appDB;
  }
  runInNewContext(source, {
    Mongo,
    process: { env: { MONGO_HOST: "mongodb-0.mongodb.mongo-bench-db-dev.svc.cluster.local:27017", MONGO_INITDB_ROOT_USERNAME: "admin", MONGO_INITDB_ROOT_PASSWORD: "test-only", MONGO_APP_PASSWORD: "app-test-only" } },
    sleep: () => state.sleeps++,
    print: () => {},
  });
  return state;
}

test("initializes an empty replica set and creates a database-scoped application user", () => {
  const state = bootstrap();
  assert.equal(state.initiations, 1);
  assert.equal(state.creations, 1);
});

test("handles mongosh throwing NotYetInitialized instead of returning a command error", () => {
  assert.equal(bootstrap({ throwNotInitialized: true }).initiations, 1);
});

test("retries connections while the official image initializes its root user", () => {
  const state = bootstrap({ failFirstConnection: true });
  assert.equal(state.sleeps, 1);
  assert.equal(state.initiations, 1);
});

test("reruns against an existing disk without resetting the replica set or existing user", () => {
  const state = bootstrap({ initialized: true, existingUser: true });
  assert.equal(state.initiations, 0);
  assert.equal(state.creations, 0);
});

test("fails when regenerated credentials do not match an existing user", () => {
  assert.throws(() => bootstrap({ initialized: true, existingUser: true, appAuth: false }), /restore the original credentials/);
});
