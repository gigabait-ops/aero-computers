-- English chat texts (the Chat Box on the supply computer).
-- "{x}" is a parameter, "{x:item}" an item name, "{x:hut}" a building name
-- (both translated by the game). A key missing in another language uses these.
return {
    ["system.started"] = "Colony supply is running",

    ["colony.attack"] = "The colony is under attack!",
    ["colony.raid"] = "Raiders are attacking the colony!",
    ["colony.grave"] = "A citizen died: there is a grave ({count} in all)",
    ["colony.citizen_new"] = "New citizen: {name} ({count}/{limit})",
    ["colony.full"] = "The colony is full: {count}/{limit}, new citizens need housing",
    ["colony.hungry"] = "Hungry citizens: {count}. The restaurant needs food",

    ["building.built"] = "Built: {hut:hut}",
    ["building.upgraded"] = "Upgraded: {hut:hut} to level {level}",

    ["supply.missing"] = "Storage has no {item:item} for {target:hut}",
    ["supply.missing_stock"] = "Storage has no {item:item} for the colony's stock",
    ["supply.missing_build"] = "Storage has no {item:item} for building",
    ["supply.crafting"] = "Craft ordered: {item:item} for {target:hut}",
    ["supply.crafting_stock"] = "Craft ordered: {item:item} for the colony's stock",
    ["supply.crafting_build"] = "Craft ordered: {item:item} for building",
    ["supply.ordered"] = "Ordered from storage in {minutes} min:",
    ["supply.delivered"] = "Delivered to the colony in {minutes} min:",
    ["summary.more"] = "…and {count} more kinds",
}
