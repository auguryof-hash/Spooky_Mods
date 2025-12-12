-----------------------------------------------------------
-- Advanced Trajectory – Aim Texture & Reticle Rendering
--
-- Intent:
-- This file is responsible for all on-screen aiming visuals
-- (crosshair, canted laser dot, glow, breathing, flicker).
--
-- It is a pure *client-side visual module*:
-- - Reads aim, recoil, stress, and stance state
-- - Renders crosshair or canted-dot accordingly
-- - Does NOT apply gameplay logic or networking
--
-- Key Responsibilities:
-- - Render standard Advanced Trajectory crosshair
-- - Render canted laser dot when SPK.isCanted() is true
-- - Interpret laser color from weapon stock (Multi_Laser / Laser)
-- - Apply color-driven behavior (red flicker, green breathe, blue bloom)
--
-- Explicit Non-Goals:
-- - No stance authority
-- - No networking
-- - No weapon state mutation
--
-- Dependencies:
-- - Advanced_trajectory_core.lua (aim state + alpha)
-- - SPK (canted stance query only)

-- Design Notes:
-- - Canted aiming is treated as a distinct visual mode
-- - No accuracy or penetration logic is modified here
-- - Laser color behavior is visual-only (flicker, bloom,
--   breathing) and does NOT affect hit calculation

-----------------------------------------------------------




local Advanced_trajectory = require "Advanced_trajectory_core"

Advanced_trajectory.panel = ISPanel:derive("Advanced_trajectory.panel")

-- Because of when this initializes, we don't require movutil til it's declared ingame. Alphabetic lua and all that too 

function Advanced_trajectory.panel:initialise()
    ISPanel.initialise(self);
end

function Advanced_trajectory.panel:noBackground()
    self.background = false;
end

function Advanced_trajectory.panel:close()
    self:setVisible(false);
end

-- Read laser color from the STOCK (Multi_Laser/Laser). Always returns r,g,b in [0..1].
local function getLaserRGB(weapon)
    if not weapon or not weapon.getStock then
        return 1.0, 0.0, 0.0 -- default laser red
    end

    local stock = weapon:getStock()
    if not stock then
        return 1.0, 0.0, 0.0
    end

    -- Only use items actually tagged as lasers
    if not (stock.hasTag and (stock:hasTag("Laser") or stock:hasTag("Multi_Laser"))) then
        return 1.0, 0.0, 0.0
    end

    --------------------------------------------------
    -- 1) Try runtime color (setColor*/getColor*)
    --------------------------------------------------
    local cr = stock.getColorRed   and stock:getColorRed()   or nil
    local cg = stock.getColorGreen and stock:getColorGreen() or nil
    local cb = stock.getColorBlue  and stock:getColorBlue()  or nil

    local r, g, b

    if cr and cg and cb then
        -- GunFighter convention: 1,1,1 means "no specific color" → use script color.
        if cr == 1 and cg == 1 and cb == 1 then
            r = stock.getR and stock:getR() or cr
            g = stock.getG and stock:getG() or cg
            b = stock.getB and stock:getB() or cb
        else
            r, g, b = cr, cg, cb
        end
    else
        --------------------------------------------------
        -- 2) No runtime color: use script color (ColorRed/Green/Blue)
        --------------------------------------------------
        r = stock.getR and stock:getR() or 1
        g = stock.getG and stock:getG() or 0
        b = stock.getB and stock:getB() or 0
    end

    --------------------------------------------------
    -- 3) Normalize in case anything is still 0–255
    --------------------------------------------------
    local function norm(v)
        v = tonumber(v or 0) or 0
        if v > 1 then v = v / 255 end
        if v < 0 then v = 0 end
        if v > 1 then v = 1 end
        return v
    end

    return norm(r), norm(g), norm(b)
end

-- Utility clamp
local function atClamp(v, minv, maxv)
    if v < minv then return minv end
    if v > maxv then return maxv end
    return v
end


-- vertical offset scaled by multiper + green
local function getBreathingOffset(multiper, green, t)
    -- normalize multiper into 0..1 recoil-ish factor
    local baseMin = 14   -- existing floor for multiper
    local range   = 20   -- how fast it ramps
    local recoilNorm = atClamp((multiper - baseMin) / range, 0, 1)

    if recoilNorm <= 0 then return 0 end

    -- Stronger scaling with green: all colors breathe, green bounces hardest
    local g = green or 0
    local ampBase  = 0.5        -- base pixels
    local ampGreen = 2.0 + 4.0 * g   -- up to ~3.5× for full green
    local amp      = ampBase * ampGreen * recoilNorm

    local freqBase = 1.0        -- Hz-ish
    local freqGreen = 2.0 + 4.0 * g  -- greener = faster breathing
    local freq     = freqBase * freqGreen

    return math.sin(t * freq) * amp
end


-- standard time in seconds for breathing / glow / flicker
local function atGetTimeSeconds()
    if getTimestampMs then
        return getTimestampMs() / 1000.0
    end
    return 0
end


--************************************************************************--
--** ISPanel:render
--**
--************************************************************************--
function Advanced_trajectory.panel:prerender()
    local posx = getMouseX() - self.width/2
    local posy = getMouseY() - self.height/2
    self:setX(posx); self:setY(posy)

    local multiper   = Advanced_trajectory.aimnum * 3
    if multiper < 14 then multiper = 14 end
    local texturescal = 14

    local transparency = Advanced_trajectory.alpha

    -- Detect canted once, up front
	local isCanted = false
	if SPK and SPK.isCanted then
		isCanted = SPK.isCanted()
	end


	if isCanted then
		local player = (self.player or getSpecificPlayer(0) or getPlayer())
		local weapon = player and player:getPrimaryHandItem() or nil
		local stock  = weapon and weapon:getStock() or nil
		local hasLaser = stock and stock.hasTag
			and (stock:hasTag("Multi_Laser") or stock:hasTag("Laser"))

		if hasLaser and self.dotCoreTex and self.dotGlowTex then
			---------------------------------------------------
			-- BASIC COLOR + BASE ALPHA
			---------------------------------------------------
			local cr, cg, cb = getLaserRGB(weapon)      -- 0..1 per channel
			local baseAlpha  = math.max(0.5, math.min(0.9, transparency + 0.15)) -- sets a min/max regardless of natural alpha modifiers

			---------------------------------------------------
			-- RECOIL FACTOR FROM multiper
			---------------------------------------------------
			local recoilNorm = atClamp((multiper - 14) / 20, 0, 1)

			---------------------------------------------------
			-- BLUE: DOT SIZE BLOOM (bigger with recoil + blue)
			---------------------------------------------------
			local dotBaseSize = 24                      -- base px size
			local blueFactor  = cb or 0

			-- Make blue bloom noticeable: all dots grow with recoil,
			-- but blue lasers bloom the most.
			local baseBloom   = 0.1                    -- minimum bloom at full recoil
			local blueBoost   = 1.0 + 3 * blueFactor  -- up to 3x effect at full blue
			local sizeBloom   = recoilNorm * baseBloom * blueBoost
			local dotSize     = dotBaseSize * (1.0 + sizeBloom)

			---------------------------------------------------
			-- TIME BASE FOR BREATHING / FLICKER
			---------------------------------------------------
			local t = atGetTimeSeconds()

			---------------------------------------------------
			-- GREEN: VERTICAL BREATHING OFFSET (movement only)
			---------------------------------------------------
			local offsetX, offsetY = 2, 35
			local cx = (self.width  / 2) - (dotSize / 2) + offsetX
			local cy = (self.height / 2) - (dotSize / 2) + offsetY

			local breatheOffsetY = getBreathingOffset(multiper, cg or 0, t)
			cy = cy + breatheOffsetY

			---------------------------------------------------
			-- RED: GLOW PULSE RATE + ALPHA FLICKER (no size flicker)
			---------------------------------------------------
			local redFactor = cr or 0

			-- Glow pulse speed: base + redFactor
			local glowPulseSpeed = 2.0 + redFactor * 6.0
			local glowPulse = 0.18 + 0.06 * math.sin(t * glowPulseSpeed)

			-- Opacity flicker: kicks in with recoil AND red; affects both dot + glow
			local flickerStrength = recoilNorm * redFactor  -- 0..1
			local opacityJitter   = 0
			if flickerStrength > 0 then
				local flickerFreq = 12.0 + redFactor * 6.0

				-- Up to ~80% alpha swing when fully red + full recoil
				local flickerAmp = 0.1 + 0.5 * flickerStrength
				opacityJitter = flickerAmp * math.sin(t * flickerFreq)
			end

			local dotA = baseAlpha * (1.0 + opacityJitter)
			dotA = atClamp(dotA, 0.05, 1.0)

			---------------------------------------------------
			-- GLOW (radius + pulse; no positional/size jitter from red)
			---------------------------------------------------
			local glowSize = dotSize * (2.2 + recoilNorm * 0.4)

			self:drawTextureScaled(
				self.dotGlowTex,
				cx - (glowSize - dotSize) / 2,
				cy - (glowSize - dotSize) / 2,
				glowSize, glowSize,
				dotA * glowPulse,
				cr, cg, cb
			)

			---------------------------------------------------
			-- CORE DOT
			---------------------------------------------------
			self:drawTextureScaled(
				self.dotCoreTex,
				cx, cy,
				dotSize, dotSize,
				dotA,
				cr, cg, cb
			)
		end

		return -- skip normal reticle when canted
	end







    -- === NOT CANTED: original color logic and full crosshair ===
    local AR,AG,AB = 1,1,1
    AR = getSandboxOptions():getOptionByName("Advanced_trajectory.crosshairRedMain"):getValue()
    AG = getSandboxOptions():getOptionByName("Advanced_trajectory.crosshairGreenMain"):getValue()
    AB = getSandboxOptions():getOptionByName("Advanced_trajectory.crosshairBlueMain"):getValue()

    if Advanced_trajectory.aimnum <= 4 then
        AR = getSandboxOptions():getOptionByName("Advanced_trajectory.crosshairRed"):getValue()
        AG = getSandboxOptions():getOptionByName("Advanced_trajectory.crosshairGreen"):getValue()
        AB = getSandboxOptions():getOptionByName("Advanced_trajectory.crosshairBlue"):getValue()
    end

    if Advanced_trajectory.isOverDistanceLimit then
        AR = getSandboxOptions():getOptionByName("Advanced_trajectory.crosshairRedLimit"):getValue()
        AG = getSandboxOptions():getOptionByName("Advanced_trajectory.crosshairGreenLimit"):getValue()
        AB = getSandboxOptions():getOptionByName("Advanced_trajectory.crosshairBlueLimit"):getValue()
    end

    if Advanced_trajectory.isOverCarAimLimit then
        AR, AG, AB = 0.9, 0.1, 0.1
    end

    local shakyEffect = Advanced_trajectory.stressEffect + Advanced_trajectory.painEffect + Advanced_trajectory.panicEffect
    if shakyEffect > 10 then shakyEffect = 10 end

    self:drawTextureScaled(self.texturetable[1], (self.width/2 -texturescal/2)           - ZombRand(shakyEffect), (self.height/2 - multiper- texturescal/2)  - ZombRand(shakyEffect),  texturescal, texturescal, transparency, AR, AG, AB)
    self:drawTextureScaled(self.texturetable[2], (self.width/2 +multiper -texturescal/2) + ZombRand(shakyEffect), (self.height/2 -texturescal/2)             + ZombRand(shakyEffect),  texturescal, texturescal, transparency, AR, AG, AB)
    self:drawTextureScaled(self.texturetable[3], (self.width/2 -texturescal/2)           - ZombRand(shakyEffect), (self.height/2 + multiper-texturescal/2)   - ZombRand(shakyEffect),  texturescal, texturescal, transparency, AR, AG, AB)
    self:drawTextureScaled(self.texturetable[4], (self.width/2 -multiper -texturescal/2) - ZombRand(shakyEffect), (self.height/2-texturescal/2)              - ZombRand(shakyEffect),  texturescal, texturescal, transparency, AR, AG, AB)
end

function Advanced_trajectory.panel:onMouseUp(x, y)
    if not self.moveWithMouse then return; end
    if not self:getIsVisible() then return; end
    self.moving = false;
    if ISMouseDrag.tabPanel then ISMouseDrag.tabPanel:onMouseUp(x,y); end
    ISMouseDrag.dragView = nil;
end

function Advanced_trajectory.panel:onMouseUpOutside(x, y)
    if not self.moveWithMouse then return; end
    if not self:getIsVisible() then return; end
    self.moving = false;
    ISMouseDrag.dragView = nil;
end

function Advanced_trajectory.panel:onMouseDown(x, y)
    if not self.moveWithMouse then return true; end
    if not self:getIsVisible() then return; end
    if not self:isMouseOver() then return end -- this happens with setCapture(true)
    self.downX = x; self.downY = y
    self.moving = true
    self:bringToTop()
end

function Advanced_trajectory.panel:onMouseMoveOutside(dx, dy)
    if not self.moveWithMouse then return; end
    self.mouseOver = false;
    if self.moving then
        if self.parent then
            self.parent:setX(self.parent.x + dx); self.parent:setY(self.parent.y + dy)
        else
            self:setX(self.x + dx); self:setY(self.y + dy); self:bringToTop()
        end
    end
end

function Advanced_trajectory.panel:onMouseMove(dx, dy)
    if not self.moveWithMouse then return; end
    self.mouseOver = true;
    if self.moving then
        if self.parent then
            self.parent:setX(self.parent.x + dx); self.parent:setY(self.parent.y + dy)
        else
            self:setX(self.x + dx); self:setY(self.y + dy); self:bringToTop()
        end
    end
end

--************************************************************************--
--** ISPanel:new
--**
--************************************************************************--
function Advanced_trajectory.panel:new (x, y, width, height)
    local o = {}
    o = ISPanel:new(x, y, width, height)
    setmetatable(o, self); self.__index = self
    o.x = x; o.y = y
    o.background = false
    o.backgroundColor = {r=0, g=0, b=0, a=0}
    o.borderColor   = {r=0, g=0, b=0, a=0}
    o.width = 0; o.height = 0
    o.anchorLeft = false; o.anchorRight = false
    o.anchorTop = false;  o.anchorBottom = false
    o.moveWithMouse = false
    o.keepOnScreen  = false

    if not getSandboxOptions():getOptionByName("Advanced_trajectory.enableOgCrosshair"):getValue() then
        o.texturetable = {
            getTexture("media/textures/Aimingtex1_1.png"),
            getTexture("media/textures/Aimingtex1_2.png"),
            getTexture("media/textures/Aimingtex1_3.png"),
            getTexture("media/textures/Aimingtex1_4.png")
        }
    else
        o.texturetable = {
            getTexture("media/textures/Aimingtex2_1.png"),
            getTexture("media/textures/Aimingtex2_2.png"),
            getTexture("media/textures/Aimingtex2_3.png"),
            getTexture("media/textures/Aimingtex2_4.png")
        }
    end
	
		-- New dedicated canted-dot textures
	o.dotCoreTex = getTexture("media/textures/RedDotCore.png")
	o.dotGlowTex = getTexture("media/textures/RedDotGlow.png")

    return o
end
