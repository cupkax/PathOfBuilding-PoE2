-- The fixture is a trimmed but otherwise untouched capture of a real Mobalytics build page.
-- The point of testing against the real shape rather than a hand-written table is drift: this
-- spec exists to tell you which upstream rebase or Mobalytics payload change broke the importer.
describe("TestMobalyticsImport", function()
	local FIXTURE = "../spec/System/fixtures/mobalytics_build.html"
	local PROFILE_FIXTURE = "../spec/System/fixtures/mobalytics_profile_build.html"
	local BUILD_URL = "https://mobalytics.gg/poe-2/builds/ice-shot-deadeye-leveling-guide"
	local PROFILE_URL = "https://mobalytics.gg/poe-2/profile/guythatdies/builds/0-5-5-gemling-twisters"

	local function fixtureHtml(path)
		path = path or FIXTURE
		local file = assert(io.open(path, "r"), "fixture missing: " .. path)
		local html = file:read("*a")
		file:close()
		return html
	end

	local importer

	before_each(function()
		newBuild()
		importer = new("MobalyticsImport"):MobalyticsImport()
	end)

	it("recognises Mobalytics build URLs and nothing else", function()
		assert.is_true(importer:Matches(BUILD_URL))
		assert.is_true(importer:Matches("http://mobalytics.gg/poe-2/builds/some_other-build"))
		-- Builds also live under a user's profile.
		assert.is_true(importer:Matches(PROFILE_URL))
		assert.is_false(importer:Matches("https://mobalytics.gg/poe-2/ranger-builds"))
		assert.is_false(importer:Matches("https://mobalytics.gg/poe-2/profile/guythatdies"))
		assert.is_false(importer:Matches("https://pobb.in/abcdef"))
		assert.is_false(importer:Matches(""))
	end)

	it("reads a build from a profile page, which uses a different accessor", function()
		local doc = assert(importer:ExtractDocument(fixtureHtml(PROFILE_FIXTURE)))
		assert.are.equal(2, #doc.data.buildVariants.values)

		assert.are.equal(2, importer:ImportDocument(build, doc))
		assert.are.equal("Mercenary", build.spec.curClassName)
		assert.are.equal("Gemling Legionnaire", build.spec.curAscendClassName)

		local titles = { }
		for _, spec in ipairs(build.treeTab.specList) do
			titles[spec.title or ""] = true
		end
		assert.is_true(titles["Early Endgame"])
		assert.is_true(titles["Taming Swap"])
	end)

	it("extracts the build document from the page payload", function()
		local doc, err = importer:ExtractDocument(fixtureHtml())
		assert.is_nil(err)
		assert.is_not_nil(doc)
		assert.are.equal(2, #doc.data.buildVariants.values)
	end)

	it("reports a useful error when the payload is missing", function()
		local doc, err = importer:ExtractDocument("<html><body>Just a moment...</body></html>")
		assert.is_nil(doc)
		assert.is_not_nil(err)
	end)

	it("creates one loadout per build variant, named after the variant", function()
		local doc = assert(importer:ExtractDocument(fixtureHtml()))
		assert.are.equal(2, importer:ImportDocument(build, doc))

		local titles = { }
		for _, spec in ipairs(build.treeTab.specList) do
			titles[spec.title or ""] = true
		end
		assert.is_true(titles["lvl 1-14"])
		assert.is_true(titles["lvl 15-23"])
	end)

	it("resolves every node, gem and item in the fixture", function()
		local doc = assert(importer:ExtractDocument(fixtureHtml()))
		importer:ImportDocument(build, doc)
		-- The whole point of the unresolved counter: an empty report means the mapping still lines
		-- up with both PoB's data and Mobalytics' payload.
		assert.are.equal("", importer:Report())
	end)

	it("imports the passive tree with the right class and ascendancy", function()
		local doc = assert(importer:ExtractDocument(fixtureHtml()))
		importer:ImportDocument(build, doc)

		assert.are.equal("Ranger", build.spec.curClassName)
		assert.are.equal("Deadeye", build.spec.curAscendClassName)

		local allocated = 0
		for _ in pairs(build.spec.allocNodes) do
			allocated = allocated + 1
		end
		-- Last variant allocates 29 main + 6 ascendancy nodes, plus the class root.
		assert.is_true(allocated >= 35)
	end)

	it("imports equipment into the matching slots", function()
		local doc = assert(importer:ExtractDocument(fixtureHtml()))
		importer:ImportDocument(build, doc)

		local function baseInSlot(slotName)
			local slot = build.itemsTab.slots[slotName]
			local item = slot and slot.selItemId ~= 0 and build.itemsTab.items[slot.selItemId]
			return item and item.baseName
		end
		-- Values are from the final ("lvl 15-23") variant, which is the one left active.
		assert.are.equal("Recurve Bow", baseInSlot("Weapon 1"))
		assert.are.equal("Broadhead Quiver", baseInSlot("Weapon 2"))
		assert.are.equal("Felt Cap", baseInSlot("Helmet"))
		assert.are.equal("Lapis Amulet", baseInSlot("Amulet"))
		assert.are.equal("Sapphire Charm", baseInSlot("Charm 1"))
	end)

	it("imports skill gems as socket groups with their supports", function()
		local doc = assert(importer:ExtractDocument(fixtureHtml()))
		importer:ImportDocument(build, doc)

		assert.are.equal(7, #build.skillsTab.socketGroupList)

		local lightningArrow
		for _, group in ipairs(build.skillsTab.socketGroupList) do
			local first = group.gemList[1]
			if first and first.gemId == data.gemForBaseName["lightning arrow"] then
				lightningArrow = group
			end
		end
		assert.is_not_nil(lightningArrow)
		-- Lightning Arrow carries two supports in this variant.
		assert.are.equal(3, #lightningArrow.gemList)
		assert.is_true(lightningArrow.gemList[2].support)
	end)

	it("leaves the build alone when there is no usable PoB code", function()
		local doc = assert(importer:ExtractDocument(fixtureHtml()))
		-- This build's pobCode is null, as most are. A stub or an undecodable code must not get
		-- as far as build:Init, which would replace the build with nothing.
		assert.is_false(importer:ImportOfficialCode(build, doc))

		doc.data.pobCode = string.rep("x", 500)
		assert.is_false(importer:ImportOfficialCode(build, doc))
		assert.is_not_nil(build.treeTab)
	end)

	it("sets character level from the variant's level band", function()
		local doc = assert(importer:ExtractDocument(fixtureHtml()))
		importer:ImportDocument(build, doc)
		-- "lvl 15-23" is imported last.
		assert.are.equal(23, build.characterLevel)
	end)
end)
