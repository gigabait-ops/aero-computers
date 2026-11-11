-- Create addresses. Saved changes work within two minutes.
--   kolonia = the colony's frogport / postbox: Create sends here
--   sklad   = your Create storage: the extra goes back here
-- One line per building (de = the hut block's x,y,z, budivlia = its kind
-- as the game names it):
--   adresa = nil       -> its packages go to kolonia, as usual
--   adresa = "Kukhnia" -> straight to that address (a packager with a
--                         frogport on the hut block)
-- New buildings are added at the end by the program; your lines stay as
-- you wrote them.
return {
    kolonia = "Colony",
    sklad = "Storage",

}
