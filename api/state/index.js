const { TableClient } = require('@azure/data-tables');

const TABLE_NAME = 'LedgerState';
const PROFILES = ['MA', 'MM'];
let clientPromise = null;

function getClient(){
  if(!clientPromise){
    clientPromise = (async () => {
      const client = TableClient.fromConnectionString(process.env.COSMOS_CONNECTION, TABLE_NAME);
      try{ await client.createTable(); }catch(e){ /* already exists */ }
      return client;
    })();
  }
  return clientPromise;
}

function getUserId(req){
  const header = req.headers['x-ms-client-principal'];
  if(!header) return null;
  try{
    const principal = JSON.parse(Buffer.from(header, 'base64').toString('utf8'));
    return principal.userId || null;
  }catch(e){
    return null;
  }
}

// MA keeps the original rowKey ('state') so existing synced data isn't
// orphaned by this change. MM (and any future profile) gets its own row.
//
// Each schema version also gets its own row. A v1 client sends no schema and
// keeps reading and writing the v1 rows, so it can never overwrite v2 state
// with a shape it doesn't understand -- and the v1 data survives as a rollback.
function rowKeyFor(profile, schema){
  const p = PROFILES.includes(profile) ? profile : 'MA';
  const v = Number(schema) >= 2 ? Math.floor(Number(schema)) : 1;
  if(v === 1) return p === 'MA' ? 'state' : `state:${p}`;
  return p === 'MA' ? `state:v${v}` : `state:v${v}:${p}`;
}

module.exports = async function (context, req) {
  const userId = getUserId(req);
  if(!userId){
    context.res = { status: 401, body: { error: 'Not authenticated' } };
    return;
  }

  let client;
  try{
    client = await getClient();
  }catch(e){
    context.log.error('Cosmos client error', e);
    context.res = { status: 500, body: { error: 'Storage unavailable' } };
    return;
  }

  if(req.method === 'GET'){
    const rowKey = rowKeyFor(req.query && req.query.profile, req.query && req.query.schema);
    try{
      const entity = await client.getEntity(userId, rowKey);
      context.res = { status: 200, headers: { 'Content-Type': 'application/json' }, body: { data: entity.data } };
    }catch(e){
      // no saved state yet for this user/profile
      context.res = { status: 200, headers: { 'Content-Type': 'application/json' }, body: { data: null } };
    }
    return;
  }

  if(req.method === 'POST'){
    const body = req.body;
    if(!body || typeof body.data !== 'string'){
      context.res = { status: 400, body: { error: 'Expected { data: "<json string>" }' } };
      return;
    }
    const rowKey = rowKeyFor(body.profile, body.schema);
    try{
      await client.upsertEntity({ partitionKey: userId, rowKey, data: body.data }, 'Replace');
      context.res = { status: 200, body: { ok: true } };
    }catch(e){
      context.log.error('Cosmos write error', e);
      context.res = { status: 500, body: { error: 'Save failed' } };
    }
    return;
  }

  context.res = { status: 405, body: { error: 'Method not allowed' } };
};
