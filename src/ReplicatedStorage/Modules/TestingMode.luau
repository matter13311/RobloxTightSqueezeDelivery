-- !! TEMPORARY - MUST be false when shipping !!
--
-- ONE switch for "let everyone try everything". While Enabled is true, for
-- EVERY player who joins:
--
--   * every vehicle costs $1 and has no delivery requirement (VehicleCatalog)
--   * every stat upgrade level costs $1 (VehicleUpgrades.CostForLevel)
--   * every zone permit costs $1 and has no delivery requirement
--     (ProgressionConfig.Permits)
--   * every paint colour is already owned (PlotManager - not written to the
--     save, so switching this off takes them away again)
--   * every game pass counts as owned: Pro Tuning, Custom Paint and the express
--     pass (PassOwnership.Owns, ExpressToll)
--
-- Materials and the induction ladder are already $1 through their own testing
-- prices (see VehiclePaint and VehicleInduction) and are not touched by this.
--
-- Shared, so the garage draws the same prices and the same unlocked cards the
-- server will honour. What a player BUYS while this is on is saved like any
-- other purchase and stays bought after it is switched off.
local TestingMode = {}

TestingMode.Enabled = true

TestingMode.PRICE = 1

return TestingMode
