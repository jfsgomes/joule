/**
 * localStorage polyfill for Next.js build workers.
 *
 * Node 25 ships a `localStorage` global, but it is only functional when the
 * process is started with a valid `--localstorage-file` path. Without one the
 * global exists while its methods do not, so any code that calls
 * `localStorage.getItem` during prerender dies with:
 *
 *   TypeError: localStorage.getItem is not a function
 *
 * That is worse than the global being absent, because the usual
 * `typeof localStorage === "undefined"` guard passes and the call still fails.
 * Several dependencies in the wallet stack read storage at module scope, so the
 * error surfaces while statically generating pages such as /blockexplorer.
 *
 * This must be injected with `NODE_OPTIONS="--require ./polyfill-localstorage.cjs"`
 * rather than imported from application code: Next spawns separate worker
 * processes for page generation, and only NODE_OPTIONS reaches all of them.
 *
 * An in-memory Map is the right backing store here. Nothing written during a
 * build should outlive it, and persisting to disk would make builds
 * order-dependent.
 */

function createStorage() {
  const store = new Map();

  return {
    getItem(key) {
      const k = String(key);
      return store.has(k) ? store.get(k) : null;
    },
    setItem(key, value) {
      store.set(String(key), String(value));
    },
    removeItem(key) {
      store.delete(String(key));
    },
    clear() {
      store.clear();
    },
    key(index) {
      const keys = Array.from(store.keys());
      return index >= 0 && index < keys.length ? keys[index] : null;
    },
    get length() {
      return store.size;
    },
  };
}

for (const name of ["localStorage", "sessionStorage"]) {
  // Overwrite unconditionally. Node 25's built-in is present but unusable
  // without --localstorage-file, so a "only define if missing" guard would
  // leave the broken one in place -- which is the actual failure mode.
  Object.defineProperty(globalThis, name, {
    value: createStorage(),
    writable: true,
    configurable: true,
    enumerable: false,
  });
}
