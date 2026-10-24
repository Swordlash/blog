// Whether this origin has an IndexedDB database of a name, asked without
// making it (Wiki.App.Backend.Mem's memWikiFound): opening a database that
// is not there makes it, so the server's administration, which offers the
// demo's data only where the demo left some, must not open it to find out.
//
// indexedDB.databases() lists the origin's databases and opens none. Where
// it is missing, the database is opened without a version, which opens one
// that is there at the version it has and, for one that is not, asks for an
// upgrade from version 0, which is aborted, so that nothing is made.
async function wiki_database_exists(name) {
  if (typeof indexedDB === "undefined") return false;
  if (typeof indexedDB.databases === "function") {
    try {
      return (await indexedDB.databases()).some((database) => database.name === name);
    } catch {
      // Fall through to opening it.
    }
  }
  return await new Promise((found) => {
    let request;
    try {
      request = indexedDB.open(name);
    } catch {
      found(false);
      return;
    }
    let made = false;
    request.onupgradeneeded = () => {
      made = true;
      request.transaction.abort();
    };
    request.onsuccess = () => {
      request.result.close();
      found(!made);
    };
    request.onerror = () => found(false);
  });
}
