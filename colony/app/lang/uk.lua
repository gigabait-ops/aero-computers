-- Українські тексти для чату (Chat Box на комп'ютері постачання).
-- "{x}" — параметр, "{x:item}" — назва предмета, "{x:hut}" — назва будинку
-- (обидві перекладає гра). Ключа нема — береться англійський текст.
return {
    ["system.started"] = "Постачання колонії працює",

    ["colony.attack"] = "Колонію атакують!",
    ["colony.raid"] = "На колонію напали рейдери!",
    ["colony.grave"] = "Загинув житель: з'явилась могила (усього {count})",
    ["colony.citizen_new"] = "Новий житель: {name} ({count}/{limit})",
    ["colony.full"] = "Колонія заповнена: {count}/{limit}, для нових жителів потрібне житло",
    ["colony.hungry"] = "Голодні жителі: {count}. Потрібна їжа в їдальні",

    ["building.built"] = "Збудовано: {hut:hut}",
    ["building.upgraded"] = "Покращено: {hut:hut} до рівня {level}",

    ["supply.missing"] = "На складі немає {item:item} для {target:hut}",
    ["supply.missing_stock"] = "На складі немає {item:item} для запасу колонії",
    ["supply.missing_build"] = "На складі немає {item:item} для будівництва",
    ["supply.crafting"] = "Замовлено крафт: {item:item} для {target:hut}",
    ["supply.crafting_stock"] = "Замовлено крафт: {item:item} для запасу колонії",
    ["supply.crafting_build"] = "Замовлено крафт: {item:item} для будівництва",
    ["supply.ordered"] = "Замовлено зі складу за {minutes} хв:",
    ["supply.delivered"] = "Доставлено в колонію за {minutes} хв:",
    ["summary.more"] = "…і ще {count} видів",
}
