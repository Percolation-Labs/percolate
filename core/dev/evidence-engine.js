// Bundled only for the optional local example; no runtime CDN or product-app dependency.
import { AsyncDuckDB, VoidLogger } from "@duckdb/duckdb-wasm";
export async function createQueryEngine(cases) {
  const worker=new Worker(new URL("duckdb-worker.js",import.meta.url));
  const db=new AsyncDuckDB(new VoidLogger(),worker);
  try {
    await db.instantiate(new URL("duckdb.wasm",import.meta.url).href);
    await db.registerFileText("cases.json",JSON.stringify(cases));
    const connection=await db.connect();
    await connection.insertJSONFromPath("cases.json",{name:"cases"});
    await connection.query("SET enable_external_access = false");
    return {close:()=>worker.terminate(),async query(sql) {
      const statement=sql.trim().replace(/;\s*$/,"");
      if(statement.includes(";"))throw new Error("Use one SELECT query, without extra semicolons.");
      const result=await connection.query(`SELECT * FROM (${statement}) AS evidence_result LIMIT 201`);
      const columns=result.schema.fields.map(f=>f.name);
      return {columns,rows:result.toArray().slice(0,200).map(row=>columns.map(name=>row[name]==null?"—":String(row[name]))),truncated:result.numRows>200};
    }};
  } catch(e) {worker.terminate();throw e;}
}
