#!/usr/bin/env bash
# Test for tools/csv_to_content.py with made-up tables.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
tool="${here}/../../tools/csv_to_content.py"
sandbox="$(mktemp -d)"
trap 'rm -rf "${sandbox}"' EXIT
failures=0
pass() { printf '  ok    %s\n' "$1"; }
fail() { printf '  FAIL  %s\n' "$1"; failures=$((failures + 1)); }

csv="${sandbox}/csv"
out="${sandbox}/out"
mkdir -p "${csv}" "${out}"
cat >"${csv}/materials.csv" <<'T'
id,density_kg_m3,flammable,ignite_s,burn_gmin_per_kg,chop,mine,cut,hammer,dig,impact_break_j,footstep,impact_sound,hit_particles
mat_a,500,1,5,10,1.0,0.5,0.5,0.5,0,0,step_a,sound_a,fx_a
T
cat >"${csv}/items.csv" <<'T'
id,name,category,stack,weight_kg,material,hold,tool_class,tier,power,durability,fuel_gmin,fuel_class,notes
thing_a,A,resource,10,0.5,mat_a,1h,,,,,7,K,
tool_a,B,tool,1,1.5,mat_a,2h,chop,1,8,90,0,,
kit_a,C,placeable,1,2,mat_a,2h,,,,,0,,
T
cat >"${csv}/item_effects.csv" <<'T'
id,kind,hunger,slot
thing_a,food,3,
fluid_a,drink,1,
T
printf 'class,swing_s,hit_s,stamina,notes\nchop,1.5,0.5,6,\n' >"${csv}/tool_classes.csv"
cat >"${csv}/build_pieces.csv" <<'T'
id,name,category,tier,slot,size_m,cost,tool_class,hp,support_base,support_v,support_h,flammable,stages,notes
piece_a,A,camp,0,free,1.0x0.5x2,kit_a:1,,50,,,,1,3,
piece_b,B,timber,1,edge,2x2x0.1,thing_a:2|tool_a:1/unit_a:4|thing_a/tool_a:3,hammer,80,,10,18,0,1,
T
printf 'id,notes\nfluid_a,\n' >"${csv}/units.csv"
cat >"${csv}/trees.csv" <<'T'
id,species,size,height_m,trunk_r_m,canopy_r_m,hp,logs,poles,sticks,extra_drops,variants,harvest_no_fell
tree_a,sp_a,mature,10,0.2,2,90,3,0,4,thing_a:1@0.25,2,thing_a:2 (cut; cooldown 4 gdays)
tree_b,sp_a,shrub,2,0.05,1,10,0,0,2,,1,thing_a:3 (hands; regrow 1.5 gdays)
T
cat >"${csv}/nodes.csv" <<'T'
id,name,tool_class,min_tier,hp,drops,biomes,world_count,respawn_gdays,cue
node_a,A,mine,1,60,thing_a:4|tool_a:1@0.4|fluid_a:1@wet,b_one;b_two,300,0,note
node_b,B,hand,0,1,thing_a:2,b_one,runtime,2,
T
printf 'table,rolls,entries\nloot_a,2,thing_a:30:1-2|nothing:70:0-0\n' >"${csv}/loot.csv"
cat >"${csv}/recipes.csv" <<'T'
id,output,qty,station,tool_class,inputs,time,time_unit,unlock,notes
rec_a,thing_a,2,piece_b,chop/cut,tool_a:1,6,swings,item:kit_a+station:piece_b,also gives thing_a:3
rec_b,tool_a,1,hand,,thing_a:2,4,s,start,
T
cat >"${csv}/animals.csv" <<'T'
id,name,hp,walk_ms,flee_ms,sense_m,flee_m,active_hours,biomes,drops,catch,max_active_phone,max_active_desktop
ani_a,A,8,1.5,9.0,18,35,05-10;22-02,b_one;b_two,thing_a:2|tool_a:1,snare or thrown stone,4,8
ani_b,B,,,,,fly 60,00-24,b_one,,none (cannot be harvested),0,0
ani_c,C,5,2.0,6.0,14,tree,06-19,b_one,thing_a:1,thrown stone,3,6
T
echo '{"kept": true}' >"${out}/other.json"

if python3 "${tool}" "${csv}" "${out}" >/dev/null; then pass "converts"; else fail "converts"; fi
check() { # description python-expression-over-items-and-mats
	if python3 -c "
import json,sys
items=json.load(open('${out}/items.json'))
mats=json.load(open('${out}/materials.json'))
pieces=json.load(open('${out}/build_pieces.json'))
rec={r['id']:r for r in json.load(open('${out}/recipes.json'))['recipes']}
tr={r['id']:r for r in json.load(open('${out}/trees.json'))['trees']}
nd={r['id']:r for r in json.load(open('${out}/nodes.json'))['nodes']}
lt=json.load(open('${out}/loot.json'))['tables']
an={r['id']:r for r in json.load(open('${out}/animals.json'))['animals']}
by={i['id']:i for i in items['items']}
sys.exit(0 if ($2) else 1)"; then pass "$1"; else fail "$1"; fi
}
check "tree model files per variant" "tr['tree_a']['models']==['tree_tree_a_1','tree_tree_a_2'] and tr['tree_b']['models']==['tree_tree_b_1']"
check "animal hours as spans" "an['ani_a']['active_hours']==[{'from':5,'to':10},{'from':22,'to':2}]"
check "animal flee distance and modes" "an['ani_a']['flee']=={'mode':'run','m':35} and an['ani_b']['flee']=={'mode':'fly','m':60} and an['ani_c']['flee']=={'mode':'tree','m':None}"
check "animal catch methods" "an['ani_a']['catch']==['snare','thrown_stone'] and an['ani_b']['catch']==[]"
check "animal without a body" "an['ani_b']['hp'] is None and an['ani_b']['drops']==[] and an['ani_a']['drops'][1]['item']=='tool_a'"
check "material flag is a bool" "mats['materials'][0]['flammable'] is True"
check "fuel object" "by['thing_a']['fuel']=={'gmin':7,'class':'K'}"
check "no fuel without class" "by['tool_a']['fuel'] is None"
check "tool swing from the class table" "by['tool_a']['tool']=={'class':'chop','tier':1,'power':8,'durability':90,'swing_s':1.5,'stamina':6}"
check "sparse effect" "by['thing_a']['effect']=={'kind':'food','hunger':3}"
check "unit with its effect" "items['units']==[{'id':'fluid_a','effect':{'kind':'drink','hunger':1}}]"
check "cost syntax" "pieces['pieces'][1]['cost']==[[{'item':'thing_a','qty':2}],[{'item':'tool_a','qty':1},{'item':'unit_a','qty':4}],[{'item':'thing_a','qty':3},{'item':'tool_a','qty':3}]]"
check "piece fields" "{k:pieces['pieces'][1][k] for k in ('size_m','support_base','support_v','stages','blocks_wind','blocks_rain','flammable','name_key')}=={'size_m':[2,2,0.1],'support_base':None,'support_v':10,'stages':1,'blocks_wind':True,'blocks_rain':False,'flammable':False,'name_key':'piece.piece_b'}"
check "free piece blocks nothing, keeps stages" "(pieces['pieces'][0]['blocks_wind'],pieces['pieces'][0]['blocks_rain'],pieces['pieces'][0]['stages'])==(False,False,3)"
check "recipe with alternatives and byproduct" "rec['rec_a']=={'id':'rec_a','output':'thing_a','qty':2,'station':'piece_b','tool_class':['chop','cut'],'inputs':[[{'item':'tool_a','qty':1}]],'time':6,'time_unit':'swings','unlock':['item:kit_a','station:piece_b'],'byproducts':[{'item':'thing_a','qty':3}]}"
check "plain recipe" "(rec['rec_b']['tool_class'],rec['rec_b']['unlock'],rec['rec_b']['byproducts'])==([],['start'],[])"
check "tree drops and harvest" "(tr['tree_a']['extra_drops'],tr['tree_a']['harvest_no_fell'])==([{'item':'thing_a','qty':1,'chance':0.25,'condition':''}],{'item':'thing_a','qty':2,'tool':'cut','cooldown_gday':4})"
check "hand harvest with regrow" "tr['tree_b']['harvest_no_fell']=={'item':'thing_a','qty':3,'tool':'hand','cooldown_gday':1.5}"
check "node drops with chance and condition" "nd['node_a']['drops']==[{'item':'thing_a','qty':4,'chance':1,'condition':''},{'item':'tool_a','qty':1,'chance':0.4,'condition':''},{'item':'fluid_a','qty':1,'chance':1,'condition':'wet'}]"
check "node lists and runtime count" "(nd['node_a']['biomes'],nd['node_a']['world_count'],nd['node_b']['world_count'],'cue' in nd['node_a'],nd['node_a']['name_key'])==(['b_one','b_two'],300,None,False,'node.node_a')"
check "loot table" "lt==[{'id':'loot_a','rolls':2,'entries':[{'item':'thing_a','weight':30,'min':1,'max':2},{'item':'nothing','weight':70,'min':0,'max':0}]}]"
check "placeable deploys its piece" "by['kit_a']['place']=={'piece':'piece_a'}"
check "poses" "[by[k]['held_pose'] for k in ('thing_a','tool_a','kit_a')]==['small_1h','tool_2h','carry_front']"
check "name key" "by['tool_a']['name_key']=='item.tool_a'"
if grep -q kept "${out}/other.json"; then pass "other files left alone"; else fail "other files left alone"; fi

printf 'thing_b,food,1,\n' >>"${csv}/item_effects.csv"
rm "${out}/items.json"
if msg="$(python3 "${tool}" "${csv}" "${out}" 2>&1)"; then fail "effect of unknown id refused"; else pass "effect of unknown id refused"; fi
if grep -q "'thing_b' is neither an item nor a unit" <<<"${msg}"; then pass "names the unknown id"; else fail "names the unknown id: ${msg}"; fi
sed -i '$d' "${csv}/item_effects.csv"
cp "${csv}/loot.csv" "${sandbox}/loot.keep"
printf 'table,rolls,entries\nloot_a,1,thing_a:5:3-1\n' >"${csv}/loot.csv"
if msg="$(python3 "${tool}" "${csv}" "${out}" 2>&1)"; then fail "min above max refused"; else pass "min above max refused"; fi
if grep -q "has min above max" <<<"${msg}"; then pass "names the bad span"; else fail "names the bad span: ${msg}"; fi
cp "${sandbox}/loot.keep" "${csv}/loot.csv"
sed -i 's/thing_a,A,resource,10,0.5/thing_a,A,resource,ten,0.5/' "${csv}/items.csv"
if msg="$(python3 "${tool}" "${csv}" "${out}" 2>&1)"; then fail "bad number refused"; else pass "bad number refused"; fi
if grep -q "items.csv:2 stack: 'ten' is not a number" <<<"${msg}"; then pass "problem names row and column"; else fail "problem names row and column: ${msg}"; fi
if [[ ! -e "${out}/items.json" ]]; then pass "nothing written on error"; else fail "nothing written on error"; fi

if ((failures)); then echo "FAILED: ${failures}"; exit 1; fi
echo "all passed"
