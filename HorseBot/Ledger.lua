local _, ns = ...

local U = ns.Util

-- The addon cannot move gold; it keeps book. Every counterparty has a single
-- balance from the local player's point of view:
--   balance > 0  -> they owe you
--   balance < 0  -> you owe them
-- The same rules apply whether you are the bookie or a punter:
--   your bet on their race          -> balance - stake
--   their bet on your race          -> balance + stake
--   payout to you / payout to them  -> balance + / - payout
--   gold received / given in trade  -> balance - / + amount
local Ledger = {}
ns.Ledger = Ledger

local HISTORY_MAX = 300

function Ledger:OnInit()
    self.balances = ns.db.ledger
    self.history = ns.db.history
end

function Ledger:Get(player)
    return self.balances[player] or 0
end

function Ledger:Add(player, delta, note)
    if not player or delta == 0 then return end
    local balance = (self.balances[player] or 0) + delta
    self.balances[player] = balance ~= 0 and balance or nil
    table.insert(self.history, 1, { t = time(), player = player, delta = delta, note = note })
    while #self.history > HISTORY_MAX do table.remove(self.history) end
    ns.Fire("LEDGER_CHANGED")
end

function Ledger:Settle(player)
    local balance = self.balances[player]
    if balance then self:Add(player, -balance, "Marked settled") end
end

function Ledger:Rows()
    local rows = {}
    for player, balance in pairs(self.balances) do
        rows[#rows + 1] = { player = player, balance = balance }
    end
    table.sort(rows, function(a, b)
        if math.abs(a.balance) ~= math.abs(b.balance) then return math.abs(a.balance) > math.abs(b.balance) end
        return a.player < b.player
    end)
    return rows
end

function Ledger:Describe(balance)
    if balance > 0 then return "owes you " .. U.FormatMoney(balance) end
    if balance < 0 then return "you owe " .. U.FormatMoney(-balance) end
    return "settled"
end

--------------------------------------------------------------------------------
-- Trade tracking: gold that changes hands with someone in the ledger is
-- booked automatically when the trade completes.
--------------------------------------------------------------------------------

local trade = {}

function Ledger:OnLogin()
    ns.RegisterEvent("TRADE_SHOW", function()
        local name, realm = UnitName("NPC")
        trade = { partner = U.FullName(name, realm), theirs = 0, mine = 0 }
    end)
    local function snapshot()
        if not trade.partner then return end
        trade.theirs = GetTargetTradeMoney() or 0
        trade.mine = GetPlayerTradeMoney() or 0
    end
    ns.RegisterEvent("TRADE_MONEY_CHANGED", snapshot)
    ns.RegisterEvent("TRADE_ACCEPT_UPDATE", snapshot)
    -- TRADE_CLOSED can fire before the completion message, so the snapshot is
    -- only cleared once it has been used or a new trade opens.
    ns.RegisterEvent("UI_INFO_MESSAGE", function(_, message)
        if message ~= ERR_TRADE_COMPLETE or not trade.partner then return end
        local partner, theirs, mine = trade.partner, trade.theirs, trade.mine
        trade = {}
        if not self.balances[partner] or theirs == mine then return end
        self:Add(partner, mine - theirs, "Trade")
        ns.Print(string.format("Trade with %s booked. %s %s.", U.ShortName(partner),
            U.ShortName(partner), self:Describe(self:Get(partner))))
    end)
end

ns.RegisterModule(Ledger)
