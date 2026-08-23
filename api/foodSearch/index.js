// Server-side food search.
//
// Proxying both providers through here rather than calling them from the page
// buys three things the browser cannot do for itself:
//   - the USDA key stays server-side (USDA deactivates keys found online, and
//     a static site publishes everything it ships)
//   - CORS stops mattering; notably Open Food Facts returns throttled
//     responses *without* CORS headers, so in the browser a 429 surfaces as an
//     opaque network failure that no client code can distinguish or report
//   - one shared cache, so two devices searching the same thing costs one call
//
// Both providers are normalised to the same shape here, so the page never has
// to know which one an item came from beyond the group label.

const USDA_KEY = process.env.FDC_API_KEY || 'DEMO_KEY';
const CACHE_TTL_MS = 60 * 60 * 1000;
const CACHE_MAX = 300;
const TIMEOUT_MS = 6000;

// per-100g nutrient ids in FoodData Central
const N_KCAL = 1008, N_PROTEIN = 1003, N_FAT = 1004, N_CARB = 1005;

const cache = new Map();

function cacheGet(key){
  const hit = cache.get(key);
  if(!hit) return null;
  if(Date.now() - hit.at > CACHE_TTL_MS){ cache.delete(key); return null; }
  return hit.value;
}
function cacheSet(key, value){
  if(cache.size >= CACHE_MAX) cache.delete(cache.keys().next().value);
  cache.set(key, { at: Date.now(), value });
}

async function getJson(url){
  const ctl = new AbortController();
  const t = setTimeout(() => ctl.abort(), TIMEOUT_MS);
  try{
    const res = await fetch(url, { signal: ctl.signal, headers: { 'User-Agent': 'caloriecounter/1.0' } });
    if(!res.ok){
      const err = new Error('http ' + res.status);
      err.status = res.status;
      throw err;
    }
    return await res.json();
  } finally {
    clearTimeout(t);
  }
}

function round(n, dp){
  const f = Math.pow(10, dp || 0);
  return Math.round(Number(n) * f) / f;
}

// Every result is expressed per ONE base unit -- per 1g, per 1ml, or per one
// item -- matching how the client stores rates, so nothing has to remember a
// divisor later. `nutrients` is omitted entirely when the provider has no
// figure: undefined means unknown, never zero.
function normalised(o){
  const out = {
    source: o.source,
    group: o.group,
    name: o.name,
    brand: o.brand || '',
    unit: o.unit,
    kcalPerUnit: round(o.kcalPerUnit, 4)
  };
  const n = {};
  if(o.protein != null) n.p = round(o.protein, 4);
  if(o.carbs   != null) n.c = round(o.carbs, 4);
  if(o.fat     != null) n.f = round(o.fat, 4);
  if(Object.keys(n).length) out.nutrients = n;
  return out;
}

// ---- USDA FoodData Central: generic and raw foods, always per 100g ----
async function searchUsda(q){
  const url = 'https://api.nal.usda.gov/fdc/v1/foods/search' +
    '?api_key=' + encodeURIComponent(USDA_KEY) +
    '&query=' + encodeURIComponent(q) +
    '&pageSize=8&dataType=' + encodeURIComponent('Foundation,SR Legacy');

  const data = await getJson(url);
  const foods = Array.isArray(data.foods) ? data.foods : [];

  return foods.map(f => {
    const by = {};
    (f.foodNutrients || []).forEach(n => {
      if(n && n.nutrientId != null && n.value != null) by[n.nutrientId] = Number(n.value);
    });
    if(by[N_KCAL] == null) return null;
    return normalised({
      source: 'usda',
      group: 'basic',
      name: f.description,
      brand: '',
      unit: 'g',
      kcalPerUnit: by[N_KCAL] / 100,
      protein: by[N_PROTEIN] != null ? by[N_PROTEIN] / 100 : null,
      carbs:   by[N_CARB]    != null ? by[N_CARB]    / 100 : null,
      fat:     by[N_FAT]     != null ? by[N_FAT]     / 100 : null
    });
  }).filter(Boolean);
}

// ---- Open Food Facts: branded and barcoded products ----
function mapOffProduct(p){
  const nut = p.nutriments || {};
  const perServing = Number(nut['energy-kcal_serving']);
  const per100 = Number(nut['energy-kcal_100g']);
  const useServing = perServing > 0;
  if(!useServing && !(per100 > 0)) return null;

  const pick = (servKey, hundredKey) => {
    const v = Number(useServing ? nut[servKey] : nut[hundredKey]);
    return Number.isFinite(v) ? v : null;
  };
  const per = v => (v == null ? null : (useServing ? v : v / 100));

  return normalised({
    source: 'off',
    group: 'branded',
    name: p.product_name,
    brand: p.brands ? String(p.brands).split(',')[0].trim() : '',
    unit: useServing ? 'unit' : 'g',
    kcalPerUnit: useServing ? perServing : per100 / 100,
    protein: per(pick('proteins_serving', 'proteins_100g')),
    carbs:   per(pick('carbohydrates_serving', 'carbohydrates_100g')),
    fat:     per(pick('fat_serving', 'fat_100g'))
  });
}

async function searchOff(q){
  // newer endpoint first, legacy as a fallback -- OFF's API layer is unstable
  let products = null;
  try{
    const d = await getJson('https://search.openfoodfacts.org/search?q=' +
      encodeURIComponent(q) + '&page_size=8&langs=en');
    products = d.hits || [];
  }catch(e){
    const d = await getJson('https://world.openfoodfacts.org/cgi/search.pl?search_terms=' +
      encodeURIComponent(q) + '&search_simple=1&action=process&json=1&page_size=8');
    products = d.products || [];
  }
  return (products || []).map(mapOffProduct).filter(Boolean);
}

module.exports = async function (context, req) {
  const q = ((req.query && req.query.q) || '').trim();
  if(q.length < 2){
    context.res = { status: 400, body: { error: 'Query too short' } };
    return;
  }

  const key = q.toLowerCase();
  const cached = cacheGet(key);
  if(cached){
    context.res = { status: 200, headers: { 'Content-Type': 'application/json' }, body: cached };
    return;
  }

  // Settled, not all: a provider being down or throttled must not take the
  // other one with it. Each reports its own state so the page can say which.
  const [usda, off] = await Promise.allSettled([searchUsda(q), searchOff(q)]);

  const body = {
    query: q,
    basic:   usda.status === 'fulfilled' ? usda.value : [],
    branded: off.status  === 'fulfilled' ? off.value  : [],
    errors: {}
  };
  if(usda.status === 'rejected'){
    body.errors.basic = String(usda.reason && usda.reason.message || usda.reason);
    context.log.warn('USDA search failed', body.errors.basic);
  }
  if(off.status === 'rejected'){
    body.errors.branded = String(off.reason && off.reason.message || off.reason);
    context.log.warn('OFF search failed', body.errors.branded);
  }

  // only cache a response that actually has something in it
  if(body.basic.length || body.branded.length) cacheSet(key, body);

  context.res = { status: 200, headers: { 'Content-Type': 'application/json' }, body };
};
