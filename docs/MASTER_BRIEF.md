# AFTERGLOW ROAD — MASTER BRIEF

> The owner's brief, stored verbatim on 2026-11-13 so it survives context
> loss. `CLAUDE.md` holds the compact operating rules; this file is the full
> specification. The earlier standing rules are appended at the end.

Read all of it, then execute it. Section 5 saves the essentials into the repo so they survive context loss.

## 0. ROLE AND MISSION
You are the lead engineer, game designer, technical artist, audio designer and release manager of a one-person studio. "The owner" directs and reviews; you do the work.
Build, end to end, a premium PAID, fully OFFLINE, single-player, open-world post-apocalyptic "slice of life" survival game for Windows, Linux, Android and iOS from ONE Godot 4 codebase, at the highest visual quality each hardware tier allows. Working title: Afterglow Road. Repo and folder: afterglow-road.
Everything is created from scratch in this repository: code, procedural generators, shaders, models, textures, audio, UI. The only outside material allowed is engine/tools and CC0-licensed assets (see 11.10), each logged in docs/ASSET_LICENSES.md with source URL, license and date. Never copy existing games, films, books, characters, logos, music, maps or names.

## 1. OPERATING RULES (non-negotiable)
1.1 Autonomy. Never ask the owner a question. When a decision is open, choose the best option, record it in docs/decisions/ADR-NNNN-title.md (context, options, choice, consequences) and continue. Only things that need a human (accounts, payments, phone play-testing, signing identities) go to handoff/NEEDS_OWNER.md as exact numbered steps; then continue with other work.
1.2 Truth. Never claim something works unless you ran it. Every report separates CHECKED (command run + result) from ASSUMED. If you cannot observe something (visual quality, game feel, phone performance) say so. For anything that can change (store rules, versions, licenses, plugin compatibility), read the official source first and cite the URL in the ADR/doc. Never invent platform facts.
1.3 Scope honesty. If a requested feature is infeasible at the stated quality on some platform, do not silently drop or fake it: write an ADR, ship the best feasible version, add the gap to docs/KNOWN_GAPS.md.
1.4 Quality. Ship-quality only: no placeholder art called final, no stubs in main, no dead code. Statically typed GDScript everywhere.
1.5 Stay inside the project directory. Install tools under ~/tools or ~/.local only. Never touch other repos, folders or the Windows C: drive. If something needs sudo you cannot do, put the exact command in NEEDS_OWNER and use a user-level alternative.
1.6 Keep working until the owner types STOP (section 4). When a milestone ends, start the next immediately. Do not wait for approval.
1.7 Owner commands: STOP, RESUME, STATUS (reply in at most 8 lines), BUILD ANDROID (build a debug APK, attach it to a GitHub Release, give 3 install steps), BUILD PC (Windows zip, attach to a Release).

## 2. ENVIRONMENT
- Windows PC + WSL2 Ubuntu. The WSL distro lives on drive D; drive C is nearly full. Work only in /mnt/d/afterglow-road (Windows D:\afterglow-road), the only copy of the project. Only the project goes there; put tools, caches and SDKs under ~/tools or ~/.local in the WSL home (also on drive D, never C). Check `df -h ~` before big downloads; if free space is under 20 GB, record it in NEEDS_OWNER.
- The owner has NO Mac. The owner reviews through downloadable builds (Windows zip, Android APK) attached to GitHub Releases, so the Windows side needs no editor setup. Write docs/OWNER_SETUP.md anyway: how to install the pinned Godot on Windows, clone to D:\ (not \\wsl$), pull, run, and install the APK on a phone.
- Use the Godot Linux binary with --headless for import, tests and exports. WSL may lack a usable GPU. For visual self-checks, try xvfb-run with Mesa software Vulkan (lavapipe) or the Compatibility renderer with software OpenGL. Build tools/screenshot/ (load a scene, advance N frames, save a PNG) and READ the PNGs to judge your own work. If rendering is impossible here, say so and use owner screenshots instead.
- Python 3 venv at ~/tools/venv (numpy, scipy, pillow, gdtoolkit) for generators. Blender (Linux build, headless: blender -b -P script.py) for procedural modelling and glTF export if installable; otherwise generate meshes in GDScript.
- Install the GitHub CLI (gh) as a user-level binary from the official releases if it is missing.

## 3. GITHUB AND GIT PROTOCOL
3.1 Remote: https://github.com/Himkush1414/afterglow-road (private, empty, created by the owner). Confirm the account with `gh api user --jq .login`; if it differs, use the real login.
3.2 Credentials: a fine-grained token limited to this repo is in the environment variable GH_TOKEN (Contents RW, Pull requests RW, Workflows RW, Metadata R). Use gh and `gh auth setup-git`. NEVER print, echo, log, store in a file, place in a URL or commit it. Never run env, printenv, set, or `gh auth token`. If it is missing or rejected, write NEEDS_OWNER, keep committing locally, and push later.
3.3 Identity: build user.email as <id>+<login>@users.noreply.github.com using `gh api user`; user.name = login. If that call fails, keep the existing git identity.
3.4 Flow for EVERY unit of work:
 a) git switch main && git pull --ff-only
 b) git switch -c <type>/<short-slug>
 c) make the change, then run tools/check.sh (it must pass)
 d) commit with Conventional Commits (feat, fix, perf, refactor, docs, test, build, chore, art, audio). One logical change per commit; every commit leaves the project importable. Imperative subject of 72 characters or fewer; add a body (what and why) when non-trivial.
 e) git push -u origin <branch> immediately after each commit.
 f) gh pr create (title; body with what, why, CHECKED/ASSUMED), then gh pr merge --merge --delete-branch (merge commits ONLY; never squash; history must stay granular), then git switch main && git pull --ff-only.
 g) Never force-push or rewrite pushed history. Never commit to main directly, except the first bootstrap commit and the handoff commit at STOP.
3.5 VOLUME COMMAND from the owner: reach at least 2,000 pushed commits AND at least 2,000 merged PRs by v1.0. Therefore make PRs small: one PR = one small, real, reviewable task (for example "Add campfire light flicker", "Add hunger decay curve test"), typically 1 to 5 commits. Count with `git rev-list --count main` and `gh pr list --state merged --limit 5000 --json number --jq length`. NEVER create empty, whitespace-only, duplicate, revert-and-redo or generated filler commits/PRs to hit the numbers. If real work seems to run out, split the remaining work into finer real tasks. A fake count is a failure.
3.6 Rate limits: wait at least 5 seconds between consecutive gh pr create/merge calls. On HTTP 403/429 or "secondary rate limit", back off 60 s, then double up to 15 min, then retry. Never loop tightly.
3.7 Large files: GitHub rejects files over 100 MB. Generators are the source of truth. Commit generator code, small inputs and small assets. Package bulk generated data (world tiles, baked textures, audio renders) as versioned zip files with checksums, attach them to a GitHub Release, and provide tools/fetch_assets.sh to download and verify them. VERIFY the current Release-asset and LFS limits in GitHub docs and record them in an ADR. Use Git LFS only if an ADR justifies it, and warn in NEEDS_OWNER before any quota is near.
3.8 CI: private-repo Actions minutes are limited (verify current numbers; macOS minutes cost multiples). Do NOT run CI on every PR. tools/check.sh runs locally before every push. Workflows: nightly headless import + tests on main, tag-triggered release builds, manual-dispatch iOS workflow (section 15). Use concurrency groups with cancel-in-progress.
3.9 Secrets hygiene: .gitignore must cover *.keystore, *.jks, .env, *.p12, *.mobileprovision, google-services*, export_credentials.cfg and builds/. Install a pre-commit hook that scans staged diffs for token patterns (ghp_, github_pat_, private-key headers, "password=") and blocks the commit. If any secret is ever committed or printed: stop, tell the owner to revoke and rotate it, and do not just delete it.
3.10 Releases: tag v0.<milestone>.0 at the end of each milestone, with builds attached to the GitHub Release. Update CHANGELOG.md only at milestone end.

## 4. STOP AND RESUME
When the owner types STOP (or "pause" or "done for today"), finish everything within 2 minutes:
1. Start nothing new. Finish only an edit that is almost done (under 30 seconds) and passes `tools/check.sh --quick`.
2. Uncommitted work: if the quick check passes, commit normally; otherwise commit to branch wip/<YYYY-MM-DD-HHMM> with a "wip:" message and push it.
3. Push everything. List open PRs; do not merge failing ones.
4. Overwrite handoff/HANDOFF.md (80 lines max): current milestone, done today (10 lines max), the in-progress item with the exact next 3 actions, branch/PR state, resume commands, known issues, pointer to NEEDS_OWNER.md. Update handoff/STATUS.md with counts (commits on main, merged PRs). Commit as `docs(handoff): ...` directly on main and push.
5. Reply with 8 lines max: pushed yes/no, branch, counts, what is next, what the owner must do.
No long documentation work at STOP.
On RESUME (or the first message of any new session): read CLAUDE.md, handoff/HANDOFF.md, handoff/NEEDS_OWNER.md, run git status and git log -5, then continue exactly where the handoff says.

## 5. FIRST ACTIONS (in this order)
1. Confirm cwd is /mnt/d/afterglow-road. Run git init -b main if needed, set the remote, verify gh auth quietly.
2. Write CLAUDE.md at the repo root: a compact version of sections 1, 3, 4, 17 and 18, so any future session obeys them even after context loss. Make the bootstrap commit to main and push.
3. Create the layout: docs/ (GDD/, story/, decisions/, art/, audio/, STORE/, ASSET_LICENSES.md, KNOWN_GAPS.md, TOOLCHAIN.md, OWNER_SETUP.md), handoff/ (HANDOFF.md, STATUS.md, NEEDS_OWNER.md), game/ (the Godot project: src/, scenes/, content/, shaders/, ui/, addons/), tools/ (check.sh, build scripts, worldgen/, assetgen/, audiogen/, screenshot/), tests/, builds/ (gitignored), .github/workflows/.
4. Install and pin the toolchain, documented with exact versions in docs/TOOLCHAIN.md: latest STABLE Godot 4.x (4.7.x at the time of writing; confirm at godotengine.org), matching export templates, JDK 17, Android SDK command-line tools with the platform and build-tools versions the pinned Godot's build template requires, GUT (Godot unit tests), gdtoolkit. Do not use the distro-packaged Android SDK.
5. Create the Godot project, tools/check.sh, the pre-commit hook, .gitignore, .gitattributes, README and a proprietary "all rights reserved" notice.
6. Then do the milestones in section 16, in order.

## 6. TECHNOLOGY DECISIONS (verify each, record in ADRs)
- Engine: Godot 4 (pinned stable). Language: statically typed GDScript. No C# (Godot docs call iOS C# export experimental). Native C++ only through third-party GDExtensions, or if profiling proves a hotspot cannot be fixed otherwise.
- Expo/EAS is NOT used. It cannot build Godot projects.
- Renderers: PC uses Forward+ (Vulkan). Mobile uses the Mobile renderer (Vulkan on Android, Metal on iOS), with Compatibility as fallback for weak Android devices. Never assume a feature exists in every renderer (SDFGI, volumetric fog, SSAO/SSIL, SSR, glow, DOF, etc.): check the docs per feature and build per-tier fallbacks.
- Physics: Jolt if the pinned Godot version supports it stably, else Godot Physics. Decide in the spike.
- Terrain: spike Terrain3D (MIT GDExtension, clipmap terrain). VERIFY: it works with the pinned Godot, ships binaries for Windows, Linux, Android arm64 and iOS, and fits mobile memory. If any platform fails, build your own chunk-streamed heightfield terrain (mesh clipmap + HeightMapShape3D collision) and write an ADR.
- Vehicles: spike VehicleBody3D against a custom raycast-suspension model; choose by stability at speed and feel on slopes and mud.
- Textures: enable ETC2/ASTC import for mobile and BPTC/S3TC for desktop (verify the exact project setting names).
- Threading: WorkerThreadPool for generation and streaming; touch the scene tree and rendering server only where the docs say it is safe.
- Large-world precision: default Godot builds use 32-bit floats. Keep the playable area within about +/-4.5 km of the origin and implement floating-origin rebasing. Consider double-precision builds only if an ADR proves them necessary.

## 7. THE GAME: VISION
Genre and tone: quiet, contemplative open-world survival; slice of life at the end of the world. The collapse already happened. The world is overgrown and beautiful, dangerous mostly at night. Production values, pacing and atmosphere should feel like a premium AAA open-world game; use that as a quality bar only, never copy.
Pillars: (1) Calm over chaos: daily rituals matter. (2) A world worth getting lost in. (3) Your van is your home. (4) Survival with dignity: systems create stories, not grind. (5) Offline, fair, premium: no ads, no IAP, no online requirement, no telemetry.
Setting: "The Afterglow": nine nights of coloured sky, after which power grids and most digital electronics died for good (old mechanical engines and simple 12V lighting still work). Most people vanished or went to the coast. A bioluminescent ecology began to spread.
Protagonist: "the Wayfarer", a former courier; the player chooses the name and a small set of appearance options. Their late mother's old van, "Marigold", is their home.
Main story "The Postcard Road": a box of postcards from the Wayfarer's younger sibling, who travelled to the coastal town Harrow Light. Each postcard shows a real place on the map; following them is the main quest. Act I the Basin (learn to live, repair the van, first postcards), Act II the Crossing (river, the city Veridian, the mountain pass), Act III the Coast. Three endings (settle in the Basin, continue the road, deliver the letters). Target playtime: about 12-15 h main story, 30+ h for everything.
First 30 minutes: dawn in the van at a roadside overlook, a looping analog radio message, a first postcard, and a gentle tutorial through real chores (boil water, patch a tire, make a meal). No combat before the player has seen the world's beauty.
Rating target: Teen/12+: non-gory creature threat, mild peril, no real brands, no real-world-actionable medical or foraging advice (add a disclaimer in the credits).

## 8. THE WORLD
Name: the Meridian Basin. Size: 8 km x 8 km (64 sq km), fixed-seed procedural world generated once and frozen, so every player gets the same map. Size without density is bad design: something notable at most every 150 m along main paths and every 400 m anywhere; no dead zone over 500 m.
Layout: pine highlands in the northwest with a ruined ski lodge; the river Silverrun flowing northwest to southeast; Mirror Lake in the centre-west; farmland plains in the centre; marsh in the south; sea to the east and south with cliffs, beaches and the Harrow Light lighthouse; the ruined city Veridian (about 1.5 x 1.5 km, around 120 enterable interiors built from about 25 modular kits) along the river in the centre-east; 4 towns; 10 villages; 30 farms and hamlets; 150+ points of interest (school, hospital, mall, drive-in cinema, campground, quarry, dam, power station, airfield, radio tower, rail line, tunnel, bridges, gas stations, wrecked convoys); a highway loop plus rural roads and trails.
Generation pipeline (tools/worldgen, deterministic, seeded): fBm + domain-warped heightfield with hand-placed constraints, hydraulic erosion, flow-accumulation rivers that carve the terrain, biome map from altitude/moisture/slope, road network by cost-based A*, rule-based settlement and POI placement, forest density from noise plus clearings. Hero locations and every story-critical site are hand-authored scenes. Validation: every POI and story site is reachable on foot and by road, slope limits respected, no floating or buried props.
Streaming: chunked cells (size chosen in the spike), async loading in a worker pool, LOD rings, origin rebasing, strict hitch budget (frame spikes over 50 ms while travelling count as bugs).
Navigation: no minimap. Paper map, compass, found maps that reveal regions, player-placed pins.
Time and seasons: 36 real minutes per in-game day by default (configurable), 4 seasons of 8 days. Sun path, moon phases, stars. Weather states: clear, overcast, fog, light rain, storm, snow, heat. Rare "Afterglow nights" with a spectacular aurora and heightened bioluminescent fauna. Weather affects temperature, visibility, wetness, audio, creature behaviour and vehicle traction.

## 9. PLAYER AND SYSTEMS (write each in full in docs/GDD with data tables, and implement)
9.1 Movement and controls: first-person primary, third-person toggle if animation quality allows (else first-person only at 1.0, via ADR). Walk, sprint, crouch, jump, vault low obstacles, ladders, shallow and deep swimming, lean, slopes, surface-based footsteps. Input: keyboard+mouse, gamepad (Steam Deck friendly), touch (virtual stick, look drag, contextual buttons, left/right-handed layouts, UI scale, safe areas, haptics). Look-at interaction with hold-to-use.
9.2 Vitals: health, stamina, hunger, thirst, body temperature, fatigue (sleep), comfort (morale), wetness; injuries (cuts and bleeding, sprains, infection, sickness from raw food or dirty water). Tunable data tables. Death is soft ("collapse": wake at the last camp or van, lose time and some items); optional hardcore mode.
9.3 Inventory: weight plus slots. Pockets, daypack, hiking pack, van storage, camp crates. Equipment slots (head, torso, legs, feet, hands, backpack, tool belt); warmth and waterproofing; item condition. 8-slot hotbar, radial menu on mobile. Eating and camp kit: canteen, mess tin, utensils, camp stove, first-aid kit, sewing kit, repair kit, water filter, lantern, flashlight, binoculars, camera, journal, map, compass, radio.
9.4 Crafting: data-driven recipes. Stations: by hand, campfire, workbench, stove, vehicle bench. Blueprints from notes and books. Light perks (Foraging, Cooking, Mechanics, Woodcraft, Fieldcraft) levelled by use.
9.5 Gathering: tree felling (axe and saw, several species, directional felling with a physical fall, logs, branches, bark, resin, stumps, saplings that regrow across seasons); scavenging containers, lockers and vehicles; foraging (berries, nuts, herbs, mushrooms with a risk and identification skill); fishing (rod, bait, species by water, time, weather); hunting and trapping (small game and deer, non-gory, butchering); water (rivers need purification, rain collectors, wells). Every world change is stored as a delta (per-chunk bitsets and dictionaries), never as a full world copy.
9.6 Camp and building: tent, campfire, lean-to, then a modular shelter (foundations, floors, walls, doors, windows, roofs, stairs, fences) with a snap system, simple structural stability, placement validation and terrain limits. Furniture: bed, storage, table, shelves, stove, workbench, rain collector, garden beds, clothes line, lantern posts, decorations. A comfort score gives bonuses. Defence: alarms, traps, fences. Cap the number of camps and building pieces for performance.
9.7 Cooking and farming: 60+ food recipes, spoilage timers, preservation (smoking, drying, canning), simple nutrition with a variety bonus. Farming: 12+ crops by season, watering, insect pests, harvest, seed saving. Stretch: beekeeping.
9.8 Vehicles: drivable van Marigold (mobile home: bed, kitchenette, storage), bicycle, pickup, hatchback, tractor; motorbike as stretch. Systems: engine, fuel, tyres, suspension, brakes, body, headlights, storage racks. Build and upgrade by salvaging parts from wrecks in a vehicle workshop UI with part slots, weight and handling effects. Damage and repair. Fuel from jerrycans and siphoning, slowly degrading. Surface effects (mud, sand, snow, ice), river fording limits. Parking equals camp (sleep, cook, store). Abandoned cars are physical obstacles you can push.
9.9 Creatures and insects:
 - Ambient wildlife: deer, rabbits, foxes, boar, crows, fish, frogs, butterflies, bees, dragonflies, fireflies, moths, mosquitoes at dusk near water, cicadas and crickets in audio layers.
 - "Afterglow fauna" (small monsters, realistic-looking, designed around what procedural generation can credibly achieve, so arthropods and birds first): Gloamers (palm-sized bioluminescent moth swarms, harmless, attract others), Ashcrawlers (cat-sized chitinous night scavengers in packs), Thornhogs (small spined boar, defensive charge), Bogwrigglers (marsh swarms), Hollowbirds (steal food from camps), Veil spiders (web ambushes in ruins), Rust mites (swarm that damages parked vehicle parts). One optional rare avoid-only set piece. No large boss monsters at 1.0.
 - Each species has a sheet and a behaviour state machine (idle, forage, alert, flee, stalk, attack, retreat), senses (vision cone, hearing, smell with wind), day/night schedules, nests as spawn points, and reactions to light, fire, noise and food. Combat: light stamina-based melee (hatchet, machete, crowbar), slingshot, throwables (flares, noisemakers), traps, stealth. No gore: creatures retreat or collapse. Creatures drop crafting items (chitin, glands, silk).
9.10 People and narrative: at most 8 named survivors with small hand-written arcs (the world is lonely; most people are heard through radio, letters and notes). Branching dialogue system with conditions and variables. 20+ side stories (for example delivering a seedling, repairing an old woman's radio, teaching a child to fish). In-world radio station with scheduled broadcasts. Journal: quests, notes, letters, bestiary, recipes, map, photo album. Photo mode: free camera, DOF, filters, saved locally.
9.11 Save system: 3 manual slots plus autosave; world = seed + deltas; versioned schema with migrations; atomic writes (temp file then rename); checksum and backup rotation; autosave on app pause/background (mobile) and before sleeping or loading; no network.
9.12 Settings and accessibility: graphics tier auto-detect and manual, FPS cap, resolution scale, upscaling where available, view distance, shadows, foliage density, audio sliders, subtitles with speaker names and size, colour-blind modes, remappable controls, UI scale, reduce camera motion, hold/toggle options, all strings in translation tables (English first, localization-ready).

## 10. UI AND UX
Minimal, togglable HUD; diegetic wherever possible. One design system (colours, type, vector icons authored as SVG in the repo). Inventory, crafting and building UIs designed for mouse, gamepad AND touch. Non-blocking onboarding. Mobile: landscape only, respect notches and safe areas, handle interruptions (calls, backgrounding), battery-saver mode (30 fps cap, reduced effects), and reduce load when sustained frame-time spikes suggest thermal throttling. Credits screen with a third-party licenses screen. Legal and privacy screen.

## 11. GRAPHICS AND ASSET PIPELINE
Goal: physically based, filmic, grounded realism with considered colour grading; not cartoon. Do not promise more than the tier can deliver; document the gap.
11.1 Lighting: dynamic time-of-day sun and moon with cascaded shadows; custom atmospheric sky shader (scattering approximation), shader-based clouds, night aurora, stars. PC: best available GI (SDFGI or equivalent), SSAO/SSIL, volumetric fog for light shafts, glow, upscaling, auto-exposure, filmic tonemap plus LUT grading. Mobile: cheap ambient/probe lighting, light fog, simple shadows. Interiors: lightmaps or probes if feasible in this toolchain, otherwise ambient + local lights. Verify every effect per renderer before relying on it.
11.2 Terrain materials: height-blended PBR layers, triplanar on cliffs, macro variation and anti-tiling, wetness, snow accumulation, mud, footprints and tyre tracks (decals or deformation).
11.3 Vegetation: 8+ tree species (plus saplings, dead and burnt variants), shrubs, ferns, reeds, flowers, grass, moss. Generated procedurally (L-systems or space colonization), LODs, imposters for far trees, global wind shader, seasonal colour, leaf-fall, snow, MultiMesh instancing per chunk, grass bending near the player at high tiers.
11.4 Architecture and props: modular kits (houses, shops, industrial, farm, road), weathering shaders (rust, moss, dirt, water stains), interior dressing that tells small stories, parametric generators for variety.
11.5 Water: river, lake and sea shaders with flow maps, waves, shoreline foam, refraction, depth fade, rain ripples; caustics only at the highest PC tier.
11.6 Characters and creatures: PBR materials, cheap skin and cloth shaders, procedural IK plus authored clips. HONEST LIMIT: if humanoid animation cannot reach the bar, reduce on-screen human presence by ADR (first-person hands, few NPCs).
11.7 VFX: GPU particles for fire, smoke, embers, dust, rain, snow, insects; flickering fire light.
11.8 Quality tiers: mobile Low/Medium/High; PC Low/Medium/High/Ultra; benchmark-based auto-detect; dynamic resolution scaling.
11.9 Budgets: define per-asset-class budgets (triangles, texture size, draw calls) in docs/art/BUDGETS.md and enforce them in tools/check.sh where possible.
11.10 Pipeline and licensing: tools/assetgen (Blender headless + Python), procedural PBR textures from noise (packed ORM), auto-LOD, everything reproducible from seeds. CC0 only (for example Poly Haven, ambientCG, Quaternius, Kenney), and ONLY after reading the license on each asset page; log each in docs/ASSET_LICENSES.md. Never use assets with unclear terms. Keep docs/STORE/AI_DISCLOSURE.md describing what content was generated by tools or AI, for store disclosure forms.

## 12. AUDIO
All sound is designed or synthesized from scratch in tools/audiogen (Python/numpy): wind, rain, fire, footsteps per surface, tool impacts, chopping, creature calls, vehicle engine (RPM-layered loops with crossfades), UI sounds. CC0 audio only if synthesis fails, logged. Music: composed in code, synthesized, sparse and emotional, adaptive layers (explore, camp, night, danger), diegetic cassette tapes and radio. Buses: Master, Music, SFX, Ambience, UI, Radio. Reverb zones per space type, raycast occlusion with low-pass, tuned attenuation, weather-aware ambience, streaming limits for mobile memory. No voice acting at 1.0: text with subtitles plus synthesized non-verbal vocalizations (ADR if this changes).

## 13. PERFORMANCE TARGETS (meet them or document the gap in KNOWN_GAPS)
PC: 60 fps at 1080p High on a mid-range 2019-2020 GPU class; 30 fps floor at minimum spec. Mobile: stable 30 fps at Medium on recent mid-range Android (2022 or newer) and iPhone 12 or newer; optional 60 fps on flagships. Install size targets: mobile at most about 2.5 GB, PC at most about 6 GB; use Play Asset Delivery if the Play base-module limits require it (VERIFY the current limits). Build an in-game performance overlay plus a --benchmark route that writes a CSV, so the owner can run it on real devices. You cannot measure GPU or phone performance in WSL: say so, never invent numbers.

## 14. TESTING AND VERIFICATION
tools/check.sh runs: gdformat --check, gdlint, Godot headless import with zero errors, GUT unit tests, scene smoke-boot for every scene (--quit-after), content schema validators (items, recipes, loot, creatures, quests), world-data checksum, secret scan, file-size guard (under 95 MB). A --quick flag runs format, lint and import only. Write unit tests for every system's maths (vitals curves, crafting, save/load round-trips and migrations, spoilage, loot tables). Keep small JPEG review screenshots (300 KB or less) in docs/art/review/ per visual milestone.

## 15. PLATFORMS AND STORES (verified Nov 2026; re-check the official page before each release)
- Android / Google Play: Play requires an AAB; use an APK for owner testing. Since 31 Aug 2026 new apps and updates must target Android 16 (API 36). Godot 4.7's Android export defaults to target SDK 36 (confirm in the build config). Export with the Gradle build template, arm64-v8a required. Verify the merged manifest: targetSdkVersion 36, no unneeded permissions (release build without INTERNET). Use Play App Signing; keep the upload keystore OUTSIDE the repo (~/secrets) and tell the owner in NEEDS_OWNER to back it up. Prepare docs/STORE/PLAY_CHECKLIST.md: Data safety form ("no data collected"), content rating questionnaire, privacy-policy page (static, in docs/STORE/), store listing text. A new personal developer account (created after 13 Nov 2023) must run a closed test with at least 12 testers opted in for 14 continuous days before applying for production; organization accounts are exempt. Plan the release timeline around it.
- iOS / App Store: Godot iOS export requires macOS with Xcode. Apple requires builds made with Xcode 26 or later and the iOS 26 SDK for uploads since 28 Apr 2026. The owner has no Mac. Prepare: iOS export preset, a manual-dispatch GitHub Actions workflow on a macOS runner that exports the Xcode project, archives it and uploads to TestFlight, and docs/STORE/IOS_CHECKLIST.md (Apple Developer Program membership, App ID, certificates, provisioning, privacy manifest, App Privacy "data not collected", age rating, review notes). Credentials go in GitHub Secrets entered by the owner; never request them in chat and never run the workflow until they exist. Godot's iOS simulator supports only the Compatibility renderer, so test on a real device.
- Windows and Linux (Steam): export Windows x86_64 and Linux x86_64 builds from WSL using export templates; document a Steam depot layout and Steam Deck friendliness (controller UI, default settings). Steam Direct costs $100 per app (paid by the owner). Steam asks for a store page, capsule art, trailer and an AI-content disclosure (check the current Steam rules and fill docs/STORE/AI_DISCLOSURE.md). Any Steamworks integration (for example GodotSteam for achievements) must sit behind an interface so the game runs fully without Steam. macOS builds are out of scope for 1.0.
- All stores: no ads, no IAP, no telemetry, no online requirement.

## 16. MILESTONES (each ends with: all checks green, docs updated, KNOWN_GAPS updated, tag v0.<N>.0, build attached to a GitHub Release)
M0 Bootstrap: repo, CLAUDE.md, toolchain, project skeleton, check.sh, hooks, screenshot harness, docs skeleton.
M1 Game design documents: docs/GDD/ files 00_vision, 01_world_bible, 02_story_bible, 03_player_controls, 04_survival_systems, 05_items_crafting (full tables), 06_building, 07_vehicles, 08_creatures (one sheet per species), 09_npcs_quests, 10_graphics_tech_art, 11_audio, 12_ui_ux, 13_architecture, 14_performance, 15_platform_compliance, 16_production_plan. Expand sections 7-15 into exhaustive detail: every object, item, creature, vehicle, recipe, quest and NPC listed with stats and behaviour. Data goes into game/content/ as validated resources.
M2 Technical spikes with ADRs (go/no-go): terrain, streaming + origin rebasing, vegetation density on mobile, vehicle physics, per-renderer features, software-rendered screenshots in WSL, a signed-debug Android export from WSL (first APK of an empty scene for the owner's phone), Windows export.
M3 Core framework: autoloads, game-state machine, event bus, save/load, settings, input abstraction (keyboard, gamepad, touch), localization, audio buses, debug overlay + perf CSV, data pipeline with validators.
M4 World generator and validation (section 8), frozen seed, tile export, reachability checks.
M5 The Look: terrain materials, streaming, sky, sun, moon, stars, clouds, time of day, fog, water, weather v1, post-processing, quality tiers v1.
M6 Vegetation and ecology visuals: trees, grass, rocks, wind, seasons, LODs.
M7 Player: controller, camera, interaction, animation, footsteps, swimming, hands.
M8 Vitals, items, inventory, equipment, crafting v1 and their UI.
M9 Gathering: felling, scavenging, foraging, fishing, hunting, water, delta-saved world changes.
M10 Camp building, storage, comfort.
M11 Cooking, spoilage, preservation, farming.
M12 Vehicles: van, driving, fuel, repair, build/upgrade, van-as-home, then the other vehicles.
M13 Settlements: modular kits, towns, the city, interiors, loot economy, environmental storytelling, navigation meshes.
M14 Wildlife, insects, Afterglow fauna, combat and stealth.
M15 NPCs, dialogue, quests, main story Acts I-III, side stories, radio, journal, photo mode.
M16 Full audio pass.
M17 UI/UX polish, tutorial, accessibility, mobile touch polish.
M18 Optimization per tier; budgets verified or documented.
M19 Android pipeline: signed AAB, debug APK on a GitHub Release, Play checklist, manifest verification.
M20 PC pipeline: Windows + Linux builds, Steam depot doc, Steam Deck pass.
M21 iOS pipeline prepared (workflow, checklist), not run until the owner supplies credentials.
M22 Content completion and balancing.
M23 QA hardening: long-run soak simulation, save-corruption tests, edge cases, memory-leak checks.
M24 Store package: privacy policy, rating answers, store text, screenshot and trailer capture mode, credits and licenses.
M25 1.0 release candidate and postmortem.
Rule: if a later milestone reveals a design flaw in an earlier one, fix it by small PRs rather than working around it.

## 17. REPORTING (keep chat quiet while working)
Use the task list for progress; do not narrate steps or dump logs. Any message to the owner is 12 lines max in this form: DONE / NOT DONE / OWNER MUST DO (numbered, exact steps, where to run each) / CHECKED vs ASSUMED. Only message at: milestone ends, blockers, owner-needed actions, STOP, STATUS.

## 18. DEFINITION OF DONE FOR 1.0
All milestones M0-M25 complete; checks green; no known crash or save-corruption bug; 2,000+ real commits and 2,000+ merged PRs; signed Android AAB ready for Play; Windows and Linux builds ready for Steam; iOS workflow ready; all store documents written; every asset license logged; KNOWN_GAPS.md honest and current; a final report listing what was verified here and what only the owner can verify on real devices.

---

## Appendix: standing rules sent before the brief

1. Think and decide by yourself. Never ask me questions. If something is unclear, choose the best option, write it down in a decision file, and continue.
2. I can type STOP at any moment. You must then finish within 2 minutes: commit and push everything (work in progress goes to a wip/ branch), write handoff/HANDOFF.md with what is done and what comes next, push it, and reply in 8 lines or fewer. When I type RESUME, read the handoff and continue.
3. GitHub: the repo is https://github.com/Himkush1414/afterglow-road.git. The access token is already in the environment variable GH_TOKEN. Use it only through gh and git. Never print it, log it, write it to a file or commit it.
4. Push after EVERY commit. Work in small branches: commit, push, open a pull request, merge it with a merge commit (never squash), delete the branch, pull main, repeat. Target at least 2,000 commits and at least 2,000 merged pull requests over the project. Each PR is one small real task. Never create empty, fake or filler commits or PRs to reach the numbers.
5. Android APK: there is no Expo and no Expo token. Build the APK yourself with Godot's Android export from this WSL machine, and attach it to a GitHub Release when I type BUILD ANDROID.
6. Be honest. Separate what you actually ran and checked from what you assume.
