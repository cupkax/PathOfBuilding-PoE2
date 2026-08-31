-- Path of Building
--
-- Class: MobalyticsImport
-- Imports a Mobalytics PoE2 build page, creating one PoB loadout per Mobalytics build variant.
--
-- Everything lives in this file on purpose: this is a fork-local feature, so the only thing a
-- rebase onto upstream ever has to replay is the small hook in ImportTab.lua.
--
-- Mobalytics has no build-code endpoint (their "pobCode" field is usually null), so instead of
-- decoding a PoB code we read the SSR payload out of the page and drive the same live-build APIs
-- that the character importer uses.

local t_insert = table.insert
local dkjson = require "dkjson"

local MATCH_URL = "^https?://mobalytics%.gg/poe%-2/builds/[%w%-_]+"

-- Mobalytics equipment key -> PoB slot name.
local slotMap = {
	helmet = "Helmet", body = "Body Armour", gloves = "Gloves", boots = "Boots",
	amulet = "Amulet", belt = "Belt",
	leftRing = "Ring 1", rightRing = "Ring 2", extraRing = "Ring 3",
	flask1 = "Flask 1", flask2 = "Flask 2",
	charm1 = "Charm 1", charm2 = "Charm 2", charm3 = "Charm 3",
}

-- Weapon keys hold set1/set2 sub-tables rather than an item directly.
local weaponSlotMap = {
	mainHand = { set1 = "Weapon 1", set2 = "Weapon 1 Swap" },
	offHand = { set1 = "Weapon 2", set2 = "Weapon 2 Swap" },
}

-- Mobalytics rune slugs are "soulcore-<lowercased GGG metadata name>", so
-- "soulcore-runelightninglesser" is Metadata/Items/SoulCores/RuneLightningLesser.
-- PoB only ships rune display names, and the stem is thematic rather than mechanical
-- ("RuneLightning" is the Storm Rune), so it cannot be derived -- it has to be mapped by hand.
-- Only add entries confirmed against a real page; anything missing is counted by the unresolved
-- report rather than guessed at, so a wrong rune never lands silently.
-- The "soulcore-" namespace also covers soul cores, abyssal eyes, idols and talismans, whose PoB
-- names ("Xopec's Soul Core of Power") share nothing with their slugs. Those stay unmapped and
-- get reported; the entries below are the plain runes, matched by their granted stat.
local runeStemMap = {
	runelightning = "Storm Rune",
	runecold = "Glacial Rune",
	runefire = "Desert Rune",
	runestrength = "Robust Rune",
	runedexterity = "Adept Rune",
	runeintelligence = "Resolve Rune",
}
local runeTierMap = { lesser = "Lesser ", greater = "Greater ", perfect = "Perfect " }

-- Attribute index as PassiveSpec:SwitchAttributeNode expects it.
local attributeIndexMap = { str = 1, dex = 2, int = 3 }

---@class MobalyticsImport
local MobalyticsImportClass = newClass("MobalyticsImport")

function MobalyticsImportClass:MobalyticsImport()
	self.unresolved = { }
	return self
end

--- True if the given text is a Mobalytics PoE2 build URL.
function MobalyticsImportClass:Matches(url)
	return url ~= nil and url:match(MATCH_URL) ~= nil
end

--- Record something we could not translate. These are surfaced as a count after the import, so
--- upstream drift or a Mobalytics payload change shows up as a number instead of as a build that
--- is quietly missing half its passives.
function MobalyticsImportClass:Note(kind, what)
	self.unresolved[kind] = self.unresolved[kind] or { }
	t_insert(self.unresolved[kind], tostring(what))
	ConPrintf("MobalyticsImport: unresolved %s '%s'", kind, tostring(what))
end

function MobalyticsImportClass:Report()
	local parts = { }
	for kind, list in pairs(self.unresolved) do
		t_insert(parts, #list .. " " .. kind .. (#list > 1 and "s" or ""))
	end
	table.sort(parts)
	return #parts > 0 and (", " .. table.concat(parts, ", ") .. " unresolved") or ""
end

-- Fail loudly and by name if upstream moves one of the APIs this importer drives, rather than
-- dying on a nil call several hundred lines deep.
local function assertApi(build)
	local required = {
		["build:NewLoadout"] = build.NewLoadout,
		["build.spec:ImportFromNodeList"] = build.spec and build.spec.ImportFromNodeList,
		["build.itemsTab:AddItem"] = build.itemsTab and build.itemsTab.AddItem,
		["build.skillsTab:ProcessSocketGroup"] = build.skillsTab and build.skillsTab.ProcessSocketGroup,
	}
	for name, fn in pairs(required) do
		assert(type(fn) == "function", "MobalyticsImport: " .. name .. " is missing (upstream API changed)")
	end
	assert(type(data.gems) == "table", "MobalyticsImport: data.gems is missing (upstream API changed)")
end

--- Pull the SSR payload out of the build page and return the user-generated build document.
--- Mobalytics escapes forward slashes in this blob, so no "</script>" can appear inside a JSON
--- string and scanning to the closing script tag is safe.
function MobalyticsImportClass:ExtractDocument(html)
	local blob = html:match("window%.__PRELOADED_STATE__%s*=%s*(.-)</script>")
	if not blob then
		return nil, "No build data in page (Cloudflare challenge, or Mobalytics changed their page)"
	end
	blob = blob:gsub("%s*;%s*$", "")
	local state, _, err = dkjson.decode(blob)
	if not state then
		return nil, "Could not decode build data: " .. tostring(err)
	end
	local apollo = state.poe2State and state.poe2State.apollo and state.poe2State.apollo.graphqlV2
	for _, query in ipairs(apollo and apollo.queries or { }) do
		local entry = query.state and query.state.data and query.state.data[1]
		local documents = entry and entry.game and entry.game.documents
		local doc = documents and documents.userGeneratedDocumentBySlug
			and documents.userGeneratedDocumentBySlug.data
		if doc and doc.data and doc.data.buildVariants then
			return doc
		end
	end
	return nil, "Page contained no build document"
end

--- Ascendancy name if there is one, else the class name. ImportFromNodeList resolves either.
local function classNameFromTags(doc)
	local className, ascendName
	for _, tag in ipairs(doc.tags and doc.tags.data or { }) do
		if tag.groupSlug == "class" then
			className = tag.name
		elseif tag.groupSlug == "ascendancy" then
			ascendName = tag.name
		end
	end
	return ascendName or className
end

--- Variant id -> display title ("lvl 15-23"), taken from the content-variants widget.
local function variantTitles(doc)
	local titles = { }
	for _, block in ipairs(doc.content or { }) do
		for _, variant in ipairs(block.data and block.data.childrenVariants or { }) do
			titles[variant.id] = variant.title
		end
	end
	return titles
end

--- Mobalytics names leveling variants by level band, which is exactly the character level the
--- loadout should be costed at. "lvl 42-59" -> 59. Most variants are named things like
--- "Uber Endgame" or "100 Div Budget Setup" instead, so only trust titles that actually say
--- "lvl"/"level" -- reading a level out of anything else sets it from a currency budget.
local function levelFromTitle(title)
	local lower = title:lower()
	if not lower:find("lvl", 1, true) and not lower:find("level", 1, true) then
		return nil
	end
	local _, hi = lower:match("(%d+)%s*%-%s*(%d+)")
	return tonumber(hi) or tonumber(lower:match("(%d+)"))
end

--- gemId keyed by lowercased grantedEffectId, which is exactly what a Mobalytics gemSlug is.
--- PoB indexes gems by display name and by granted-effect object, but not by lowercased id.
function MobalyticsImportClass:GemIndex()
	if not self.gemIndex then
		self.gemIndex = { }
		for gemId, gem in pairs(data.gems) do
			if gem.grantedEffectId then
				self.gemIndex[gem.grantedEffectId:lower()] = gemId
			end
		end
	end
	return self.gemIndex
end

--- PoB keys its unique DB by "Title, Base Name" while Mobalytics gives just the title, sometimes
--- with a slot qualifier ("Darkness Enthroned (gloves)"), so match on the normalised title.
local function uniqueKey(name)
	return (name:gsub("%s*%b()", ""):gsub("^%s+", ""):gsub("%s+$", "")):lower()
end

function MobalyticsImportClass:UniqueIndex()
	if not self.uniqueIndex then
		self.uniqueIndex = { }
		for name, item in pairs(main and main.uniqueDB and main.uniqueDB.list or { }) do
			self.uniqueIndex[uniqueKey(name:match("^(.-),") or name)] = item
		end
	end
	return self.uniqueIndex
end

function MobalyticsImportClass:RuneName(slug)
	local stem = slug:match("^soulcore%-(.+)$") or slug
	for tier, prefix in pairs(runeTierMap) do
		local base = stem:match("^(.-)" .. tier .. "$")
		if base and runeStemMap[base] then
			return prefix .. runeStemMap[base]
		end
	end
	return runeStemMap[stem]
end

function MobalyticsImportClass:ImportTree(build, variant)
	local tree = variant.passiveTree
	if not tree then
		return
	end
	local hashes, weaponSets = { }, { }
	local function collect(list, setIndex)
		for _, slug in ipairs(list or { }) do
			local id = tonumber(slug:match("^node%-(%d+)$"))
			if id then
				t_insert(hashes, id)
				if setIndex then
					weaponSets[id] = setIndex
				end
			else
				self:Note("node", slug)
			end
		end
	end
	collect(tree.mainTree and tree.mainTree.selectedSlugs)
	collect(tree.ascendancyTree and tree.ascendancyTree.selectedSlugs)
	collect(tree.set1Tree and tree.set1Tree.selectedSlugs, 1)
	collect(tree.set2Tree and tree.set2Tree.selectedSlugs, 2)

	build.spec:ImportFromNodeList(self.className, nil, nil, 0, hashes, weaponSets, { }, { }, latestTreeVersion)

	-- PoE2's generic "Attribute" nodes have to be switched to the specific attribute the build
	-- takes, the same way the character importer applies the API's skill_overrides. Skipping this
	-- leaves them generic, which breaks pathing through them and silently strips every node beyond.
	for _, attribute in ipairs(tree.attributeNodes or { }) do
		local id = attribute.nodeSlug and tonumber(attribute.nodeSlug:match("^node%-(%d+)$"))
		local attributeIndex = id and attributeIndexMap[attribute.attribute]
		if attributeIndex then
			build.spec:SwitchAttributeNode(id, attributeIndex)
			local node = build.spec.nodes[id]
			if node and build.spec.hashOverrides[id] then
				build.spec:ReplaceNode(node, build.spec.hashOverrides[id])
			end
		end
		-- "any" means the author left the node unpinned, which needs no override.
	end

	-- Mobalytics stores the nodes the author picked, not the travel nodes between them -- their
	-- planner paths automatically. PoB drops anything it cannot reach from the class start, which
	-- on some builds throws away all but a handful of nodes, so re-allocate the survivors through
	-- PoB's own pathfinding, exactly as clicking a distant node in the tree would.
	-- Weapon-set nodes are excluded: ImportFromNodeList already gave them their alloc mode, and
	-- pathing to them would re-allocate them as permanent nodes in the main tree.
	for _, id in ipairs(hashes) do
		local node = build.spec.nodes[id]
		if node and not node.alloc and not weaponSets[id] then
			build.spec:AllocNode(node)
		end
	end

	-- Anything we asked for that still is not allocated is a genuine miss -- a tree-version bump,
	-- say -- and would otherwise be a silently incomplete tree.
	for _, id in ipairs(hashes) do
		if not build.spec.allocNodes[id] and not weaponSets[id] then
			self:Note("node", id)
		end
	end
	build.spec:AddUndoState()
end

--- Mobalytics ships a base name plus human-readable mod lines, which is already PoB item format.
local function rareRawText(item)
	local mods = { }
	for _, explicit in ipairs(item.explicitDescriptions or { }) do
		if explicit.description and explicit.description ~= "" then
			t_insert(mods, explicit.description)
		end
	end
	if #mods == 0 then
		return "Rarity: NORMAL\n" .. item.name
	end
	return "Rarity: RARE\n" .. item.name .. "\n" .. item.name .. "\n--------\n" .. table.concat(mods, "\n")
end

function MobalyticsImportClass:ImportItem(build, entry, slotName)
	local source = entry and entry.commonItem
	if not source or not source.name then
		return
	end
	local item
	if source.isUnique then
		-- PoB's own unique DB already holds the full item, which beats anything we could rebuild
		-- from a mod list, so use it verbatim when the name resolves.
		local known = self:UniqueIndex()[uniqueKey(source.name)]
		if not known then
			self:Note("item", source.name)
			return
		end
		item = new("Item"):Item(known.raw, "UNIQUE", true)
	else
		item = new("Item"):Item(rareRawText(source))
	end
	if not item.base then
		self:Note("item", source.name)
		return
	end
	for _, rune in ipairs(entry.runes or { }) do
		local name = rune.slug and self:RuneName(rune.slug)
		if name then
			item.runes = item.runes or { }
			t_insert(item.runes, name)
		elseif rune.slug then
			self:Note("rune", rune.slug)
		end
	end
	item:BuildAndParseRaw()
	build.itemsTab:AddItem(item, true)
	local slot = build.itemsTab.slots[slotName]
	if slot then
		slot:SetSelItemId(item.id)
	else
		self:Note("slot", slotName)
	end
end

function MobalyticsImportClass:ImportItems(build, variant)
	local equipment = variant.equipment
	if not equipment then
		return
	end
	for key, slotName in pairs(slotMap) do
		self:ImportItem(build, equipment[key], slotName)
	end
	for key, sets in pairs(weaponSlotMap) do
		for setKey, slotName in pairs(sets) do
			self:ImportItem(build, equipment[key] and equipment[key][setKey], slotName)
		end
	end
	build.itemsTab:PopulateSlots()
	build.itemsTab:AddUndoState()
end

function MobalyticsImportClass:ImportSkills(build, variant)
	local index = self:GemIndex()
	local function instance(slug, support)
		local gemId = index[slug:lower()]
		if not gemId then
			self:Note("gem", slug)
			return nil
		end
		-- Mobalytics rarely states a gem level; 20 matches the character importer's default.
		return { level = 20, quality = 0, enabled = true, enableGlobal1 = true, enableGlobal2 = true,
			count = 1, gemId = gemId, support = support }
	end
	for _, gem in ipairs(variant.skillGems and variant.skillGems.gems or { }) do
		local active = gem.activeSkill and gem.activeSkill.gemSlug
			and instance(gem.activeSkill.gemSlug, false)
		if active then
			if gem.activeSkill.level then
				active.level = gem.activeSkill.level
			end
			local group = { label = "", enabled = true, gemList = { active } }
			for _, sub in ipairs(gem.subSkills or { }) do
				local support = sub.gemSlug and instance(sub.gemSlug, true)
				if support then
					t_insert(group.gemList, support)
				end
			end
			t_insert(build.skillsTab.socketGroupList, group)
			build.skillsTab:ProcessSocketGroup(group)
		end
	end
	-- Without a main socket group the whole loadout reports zero DPS.
	if #build.skillsTab.socketGroupList > 0 then
		local guess = build.importTab and build.importTab.GuessMainSocketGroup
			and build.importTab:GuessMainSocketGroup()
		build.mainSocketGroup = guess or 1
	end
	build.skillsTab:AddUndoState()
end

-- Cached pages live beside the user's builds, which is outside the repo, so re-importing while
-- iterating on the mapping code costs Mobalytics nothing. Shift-click Import to force a refetch.
local function cachePath(url)
	local slug = url:match("/builds/([%w%-_]+)")
	if not slug or not main or not main.buildPath then
		return nil
	end
	return main.buildPath .. "mobalytics-" .. slug .. ".html"
end

local function readCache(path)
	local file = path and io.open(path, "r")
	if not file then
		return nil
	end
	local contents = file:read("*a")
	file:close()
	return contents
end

local function writeCache(path, contents)
	local file = path and io.open(path, "w")
	if file then
		file:write(contents)
		file:close()
	end
end

--- Entry point from the import tab: fetch (or reuse) the page, then translate it.
function MobalyticsImportClass:Import(importTab)
	local url = importTab.controls.importCodeIn.buf:gsub("^%s+", ""):gsub("%s+$", "")
	local path = cachePath(url)
	local cached = not (IsKeyDown and IsKeyDown("SHIFT")) and readCache(path)
	if cached then
		self:Finish(importTab, cached, "cache")
		return
	end
	importTab.importCodeFetching = true
	launch:DownloadPage(url, function(response, errMsg)
		importTab.importCodeFetching = false
		if errMsg then
			importTab.importCodeDetail = colorCodes.NEGATIVE .. "Mobalytics fetch failed: " .. errMsg
			return
		end
		writeCache(path, response.body)
		self:Finish(importTab, response.body, "page")
	end)
end

--- Mobalytics' widget payload stores only the nodes the author picked, so a tree rebuilt from it
--- runs about 60-100% complete. Many pages also carry a real PoB build code, which is exact --
--- prefer it, and keep the per-variant widget loadouts alongside it as clearly-marked extras.
function MobalyticsImportClass:ImportOfficialCode(build, doc)
	local code = doc.data.pobCode
	-- Some pages carry a stub rather than a real code.
	if type(code) ~= "string" or #code < 100 then
		return false
	end
	-- Check the payload before touching the build: Init on an empty string would leave the user
	-- with nothing. Inflate is host-provided and returns "" when it is unavailable.
	local xml = Inflate(common.base64.decode(code:gsub("-", "+"):gsub("_", "/")))
	if not xml or not xml:match("<PathOfBuilding2") then
		self:Note("pobCode", "could not be decoded")
		return false
	end
	build:Shutdown()
	build:Init(false, doc.data.name or "Mobalytics build", xml)
	return true
end

function MobalyticsImportClass:Finish(importTab, html, source)
	local doc, err = self:ExtractDocument(html)
	if not doc then
		importTab.importCodeDetail = colorCodes.NEGATIVE .. err
		return
	end
	local build = importTab.build
	local exact = self:ImportOfficialCode(build, doc)
	local count = self:ImportDocument(build, doc, exact)

	-- build:Init replaces the import tab, so report against whichever one is live now.
	local tab = build.importTab or importTab
	tab.importCodeDetail = colorCodes.POSITIVE .. string.format(
		"Imported %s%d variant loadout%s from %s%s",
		exact and "the Mobalytics PoB export plus " or "", count, count == 1 and "" or "s",
		source, self:Report())
	build.viewMode = "TREE"
end

--- Translate a whole document into loadouts, one per Mobalytics build variant. When `exact` is
--- set, an authoritative PoB export is already loaded, so these reconstructed loadouts are
--- labelled to keep the two apart.
function MobalyticsImportClass:ImportDocument(build, doc, exact)
	assertApi(build)
	self.className = classNameFromTags(doc)
	assert(self.className, "MobalyticsImport: page has no class or ascendancy tag")

	local count = 0
	local titles = variantTitles(doc)
	for index, variant in ipairs(doc.data.buildVariants.values) do
		local title = titles[variant.id] or ("Variant " .. index)
		if exact then
			title = title .. " (approx)"
		end
		-- ponytail: always makes a fresh loadout, so a new build keeps its original empty one.
		-- Reuse that first loadout instead if it ever gets annoying enough to be worth the API.
		build:NewLoadout(title)
		self:ImportTree(build, variant)
		self:ImportItems(build, variant)
		self:ImportSkills(build, variant)
		local level = levelFromTitle(title)
		if level then
			build.characterLevel = level
			build.characterLevelAutoMode = false
			build.configTab:UpdateLevel()
		end
		count = count + 1
	end
	build.buildFlag = true
	return count
end
