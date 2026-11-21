// 8Speedy Assist — offline expert system.
// Used when the Claude API key is not configured, when the AI is switched off
// in app_config, or when the model call fails. It is a real roadside-repair
// knowledge base (typical Durgapur labour + parts prices, 2026), not a mock.

export type Category = "cycle_toto" | "two_wheeler" | "four_wheeler" | "heavy_vehicle";
export type Urgency = "low" | "medium" | "high" | "emergency";

export interface Cause {
  title: string;
  probability: number;
  explanation: string;
}

export interface AssistResult {
  summary: string;
  urgency: Urgency;
  safe_to_ride: boolean;
  likely_causes: Cause[];
  suggested_issue_tags: string[];
  estimated_cost: { min_inr: number; max_inr: number; note: string };
  do_now: string[];
  avoid: string[];
  questions_for_mechanic: string[];
  diagnostic_steps: string[];
  tools_and_parts: string[];
}

interface IssueKnowledge {
  label: string;
  urgency: Urgency;
  safe: boolean;
  causes: Partial<Record<Category | "default", [string, number, string][]>>;
  cost: Record<Category, [number, number]>;
  doNow: string[];
  avoid: string[];
  ask: string[];
  steps: string[];
  tools: string[];
  keywords: string[];
}

export const ISSUE_LABELS = [
  "Puncture / Tyre Flat", "Won't Start", "Battery Dead", "Chain / Brake", "Overheating", "Fuel Problem",
  "Lights / Electrical", "Clutch / Gear", "Strange Noise", "Oil / Fluid Leak", "Key Lost / Lockout",
  "Accident / Towing", "Other",
] as const;

const KB: IssueKnowledge[] = [
  {
    label: "Puncture / Tyre Flat",
    urgency: "medium",
    safe: false,
    causes: {
      default: [
        ["Nail or sharp object in the tyre", 55, "The most common cause on city roads; the tyre loses air slowly or suddenly."],
        ["Leaking valve or valve core", 20, "Air escapes from the valve stem; often happens on older tubes or after a hard hit."],
        ["Cut tube or tyre side-wall damage", 15, "A pothole or kerb hit can pinch the tube or cut the side wall, which cannot be patched."],
        ["Bent rim / bead leak", 10, "A bent rim lets air escape where the tyre meets the wheel."],
      ],
    },
    cost: { cycle_toto: [40, 350], two_wheeler: [80, 450], four_wheeler: [150, 600], heavy_vehicle: [300, 1200] },
    doNow: [
      "Move to the side of the road and switch on the hazard lights.",
      "Do not ride or drive on the flat tyre — it destroys the tyre and can bend the rim.",
      "Put the vehicle on its stand or apply the handbrake on level ground.",
    ],
    avoid: ["Riding on a flat tyre to reach a shop", "Using quick-fix sealant on a tyre with a side-wall cut"],
    ask: ["Is it a tubeless tyre or a tube tyre?", "Can the tyre be repaired or does it need a new tube?"],
    steps: [
      "Inflate the tyre and find the leak with soapy water.",
      "Check the valve core; tighten or replace it.",
      "Tubeless: remove the object and insert a plug. Tube: patch it, replace the tube if the cut is longer than 6 mm.",
      "Check the rim for bends and the tyre for side-wall damage.",
      "Set the tyre pressure to the value on the vehicle sticker / manual.",
    ],
    tools: ["Tubeless plug kit and tube patch kit", "Portable air compressor or foot pump", "Tyre levers", "Spare tube in common sizes", "Valve cores"],
    keywords: ["puncture", "pankchar", "panchar", "pancture", "flat", "tyre", "tire", "tube", "hawa", "air nahi", "chaka", "chaaka", "wheel"],
  },
  {
    label: "Won't Start",
    urgency: "medium",
    safe: false,
    causes: {
      two_wheeler: [
        ["Weak or discharged battery", 35, "Self-start clicks or turns slowly; the horn and lights are dim."],
        ["Fouled spark plug", 20, "Carbon or fuel on the plug stops the spark, common after long idling."],
        ["Fuel not reaching the engine", 20, "Low fuel, a choked carburettor/injector or a blocked fuel filter."],
        ["Side-stand switch or kill switch engaged", 15, "Many bikes and scooters will not start with the stand down or the kill switch off."],
        ["Starter relay or starter motor fault", 10, "A single click without the engine turning points to the relay or motor."],
      ],
      four_wheeler: [
        ["Discharged battery or loose terminals", 40, "Slow cranking, clicking or dim dashboard lights."],
        ["Starter motor / solenoid fault", 20, "A single loud click with full lights usually means the starter."],
        ["Fuel pump or fuel filter problem", 15, "The engine cranks normally but does not catch."],
        ["Ignition / spark problem", 15, "Worn plugs or a failed coil, often with a check-engine light."],
        ["Immobiliser does not recognise the key", 10, "A blinking key symbol on the dashboard; try the spare key."],
      ],
      cycle_toto: [
        ["Battery pack discharged or a loose connector", 50, "E-rickshaws stop completely when one battery or a connector fails."],
        ["Controller fault", 25, "The display is on but the motor does not respond."],
        ["Throttle or key switch fault", 25, "Worn throttle sensors and key switches are common in daily use."],
      ],
      heavy_vehicle: [
        ["Battery or terminals", 35, "Slow cranking, especially in the morning."],
        ["Air in the diesel line / choked fuel filter", 30, "The engine cranks but does not start after running out of fuel or a filter change."],
        ["Starter motor fault", 20, "Clicking or grinding while cranking."],
        ["Glow plug / cold start problem", 15, "Hard starting on cold mornings."],
      ],
    },
    cost: { cycle_toto: [200, 2500], two_wheeler: [100, 900], four_wheeler: [300, 3500], heavy_vehicle: [500, 6000] },
    doNow: [
      "Bikes/scooters: check that the side-stand is up and the kill switch is ON.",
      "Check the fuel level.",
      "Do not crank for more than 5–10 seconds at a time; wait a minute between tries.",
      "Switch off lights and AC to save the battery.",
    ],
    avoid: ["Cranking again and again for a long time (drains the battery, overheats the starter)", "Push-starting a CVT scooter or an automatic car"],
    ask: ["Is it the battery or the starter?", "Do I need a new part, or can it be repaired on the spot?"],
    steps: [
      "Measure battery voltage: 12.4 V or more at rest, above 9.6 V while cranking.",
      "Clean and tighten the battery terminals.",
      "Do a spark test and check the plug condition.",
      "Check fuel delivery (pump sound, pressure / flow).",
      "Cars: read fault codes with an OBD-II scanner.",
    ],
    tools: ["Multimeter", "Jump starter or booster cables", "Spark plug spanner and spare plugs", "OBD-II scanner (cars)", "Terminal brush"],
    keywords: ["start nahi", "start nhi", "not start", "won't start", "wont start", "no start", "chalu nahi", "start hoche na", "start hocche na", "start hochhe na", "self nahi", "kick", "starting problem", "band ho gaya", "bondho"],
  },
  {
    label: "Battery Dead",
    urgency: "medium",
    safe: false,
    causes: {
      default: [
        ["Battery discharged (lights left on, short trips)", 40, "The battery is fine but empty; a jump start usually works."],
        ["Battery at the end of its life", 30, "Batteries usually last 2–4 years; an old battery cannot hold charge."],
        ["Loose or corroded terminals", 20, "White/green powder on the terminals stops current flow."],
        ["Charging system fault (regulator / alternator)", 10, "The battery goes flat again even after charging."],
      ],
      cycle_toto: [
        ["Battery pack weak or one battery dead", 50, "One weak battery in the set pulls the whole pack down."],
        ["Loose or burnt connector", 30, "Heat marks or loose lugs on the battery connectors."],
        ["Charger fault", 20, "The pack never reaches full charge overnight."],
      ],
    },
    cost: { cycle_toto: [300, 30000], two_wheeler: [100, 2500], four_wheeler: [250, 8000], heavy_vehicle: [500, 15000] },
    doNow: [
      "Switch off all lights and accessories.",
      "Check the battery age (sticker on the battery) and tell the mechanic.",
      "A jump start usually gets you moving; let the engine run 20 minutes afterwards.",
    ],
    avoid: ["Connecting jump cables the wrong way (red to +, black to − or bare metal)", "Smoking or making sparks near the battery"],
    ask: ["Can the battery be charged or does it need replacement?", "Is the charging system working?"],
    steps: [
      "Voltage and load test the battery.",
      "Clean the terminals.",
      "Jump start, then check the charging voltage (13.8–14.6 V at 2000 rpm).",
      "Replace the battery if it fails the load test.",
    ],
    tools: ["Jump starter pack", "Multimeter / battery tester", "Terminal cleaner", "Replacement battery (if the customer agrees)"],
    keywords: ["battery", "batri", "battary", "jump", "self start", "dim light", "charge nahi"],
  },
  {
    label: "Chain / Brake",
    urgency: "high",
    safe: false,
    causes: {
      two_wheeler: [
        ["Loose, dry or slipped chain", 40, "A clanking chain or one that jumps the sprocket."],
        ["Worn brake pads or shoes", 30, "Squealing, grinding or the lever going too far."],
        ["Brake cable or lever needs adjustment", 20, "Common on drum brakes after wear."],
        ["Low brake fluid / air in the line (disc brake)", 10, "The lever feels soft or spongy."],
      ],
      cycle_toto: [
        ["Chain came off or is loose", 50, "The pedals spin without moving the wheel."],
        ["Brake cable loose or broken", 30, "The brake lever pulls without stopping."],
        ["Brake pads worn", 20, "Weak braking, noise."],
      ],
      four_wheeler: [
        ["Worn brake pads", 40, "Squealing or grinding while braking."],
        ["Brake fluid leak / low fluid", 25, "Soft pedal, brake warning light on."],
        ["Sticking brake caliper", 20, "Burning smell, the car pulls to one side."],
        ["Handbrake stuck", 15, "The car feels held back; one wheel very hot."],
      ],
      heavy_vehicle: [
        ["Brake lining worn", 35, "Long stopping distance."],
        ["Air / hydraulic leak in the brake system", 35, "Low air pressure warning or soft pedal."],
        ["Slack adjuster needs adjustment", 30, "Uneven braking."],
      ],
    },
    cost: { cycle_toto: [50, 300], two_wheeler: [100, 1200], four_wheeler: [600, 4500], heavy_vehicle: [1000, 7000] },
    doNow: [
      "If the brake feels soft or does not stop the vehicle, do not ride or drive it.",
      "Park on level ground and use the stand / handbrake and a low gear.",
    ],
    avoid: ["Driving with a spongy brake pedal or lever", "Riding with a chain that keeps falling off"],
    ask: ["Are the brake pads or shoes worn out?", "Is there any brake fluid leak?"],
    steps: [
      "Check pad/shoe thickness and the disc/drum surface.",
      "Check the brake fluid level and look for leaks.",
      "Bleed the brakes if the lever/pedal is spongy.",
      "Adjust and lubricate the chain (about 20–30 mm slack) and inspect the sprockets.",
    ],
    tools: ["Brake pads/shoes for common models", "DOT 3/4 brake fluid", "Chain lube and adjusters", "Spanner set"],
    keywords: ["brake", "break", "brek", "chain", "shikal", "sikal", "chen"],
  },
  {
    label: "Overheating",
    urgency: "high",
    safe: false,
    causes: {
      two_wheeler: [
        ["Low engine oil", 35, "Old or low oil makes the engine run hot and noisy."],
        ["Low coolant (liquid-cooled bikes)", 25, "The temperature warning comes on in traffic."],
        ["Radiator fan not working", 20, "Overheats in traffic but is fine while moving."],
        ["Clogged air filter / lean mixture", 20, "Loss of power and heat."],
      ],
      default: [
        ["Coolant leak or low coolant", 40, "Steam, sweet smell or a puddle under the engine."],
        ["Radiator fan / fan relay fault", 25, "Overheats in traffic, cools down while driving."],
        ["Stuck thermostat", 15, "The temperature rises quickly even on short trips."],
        ["Water pump failure", 10, "Coolant does not circulate; often with noise or a leak."],
        ["Blocked radiator", 10, "Dirt or scale reduces cooling over time."],
      ],
    },
    cost: { cycle_toto: [150, 1500], two_wheeler: [200, 1500], four_wheeler: [500, 5500], heavy_vehicle: [800, 9000] },
    doNow: [
      "Stop the engine immediately and let it cool for 20–30 minutes.",
      "Turn off the AC.",
      "Keep a safe distance if there is steam.",
    ],
    avoid: ["Opening the radiator or coolant cap on a hot engine (it can scald you)", "Pouring cold water on a hot engine", "Driving on with the temperature light on"],
    ask: ["Is there a coolant leak?", "Is the fan working?", "Is the engine damaged?"],
    steps: [
      "After cooling, check the coolant level and look for leaks.",
      "Test the radiator fan, its fuse and relay.",
      "Check the thermostat and water pump.",
      "Pressure-test the cooling system.",
      "Check the engine oil level and condition.",
    ],
    tools: ["Coolant / distilled water", "Engine oil for top-up", "Fuse and relay set", "Cooling-system pressure tester"],
    keywords: ["heat", "garam", "gorom", "overheat", "temperature", "temp light", "steam", "bhap", "bhaap", "dhuan", "dhua", "dhoa", "smoke"],
  },
  {
    label: "Fuel Problem",
    urgency: "medium",
    safe: false,
    causes: {
      default: [
        ["Out of fuel / wrong fuel gauge reading", 30, "The gauge can show fuel when the tank is almost empty."],
        ["Choked fuel filter", 25, "The engine sputters or loses power, especially uphill."],
        ["Weak fuel pump (cars / fuel-injected bikes)", 20, "Hard starting and stalling."],
        ["Water or adulteration in fuel", 15, "Misfiring after filling at a new pump."],
        ["Fuel leak", 10, "A strong petrol/diesel smell or drips under the vehicle."],
      ],
    },
    cost: { cycle_toto: [100, 800], two_wheeler: [100, 1500], four_wheeler: [300, 6000], heavy_vehicle: [500, 8000] },
    doNow: [
      "If you smell fuel strongly or see dripping fuel: switch off, move away, no smoking or flames.",
      "Check the fuel level.",
    ],
    avoid: ["Starting the engine while fuel is dripping", "Carrying fuel in plastic water bottles"],
    ask: ["Is the fuel filter or pump faulty?", "Does the tank need cleaning?"],
    steps: [
      "Check the fuel level and gauge.",
      "Check fuel pressure / flow at the engine.",
      "Inspect the filter and lines for blockage or leaks.",
      "Drain contaminated fuel if needed.",
    ],
    tools: ["1–2 L of fuel in a proper can", "Fuel filter", "Fuel pressure gauge", "Hose clamps"],
    keywords: ["petrol", "diesel", "fuel", "tel khatam", "tank", "cng", "milege", "mileage", "pickup nahi"],
  },
  {
    label: "Lights / Electrical",
    urgency: "low",
    safe: true,
    causes: {
      default: [
        ["Blown fuse", 35, "Several things stop working at once."],
        ["Loose or corroded connector / earth wire", 25, "Lights flicker or work only sometimes."],
        ["Failed bulb or LED", 20, "Only one light is out."],
        ["Switch or relay fault", 10, "Clicking sounds or a switch that feels loose."],
        ["Short circuit in the wiring", 10, "Fuses keep blowing; burning smell."],
      ],
    },
    cost: { cycle_toto: [50, 1200], two_wheeler: [50, 900], four_wheeler: [100, 3500], heavy_vehicle: [200, 4000] },
    doNow: ["Use the hazard lights if the headlights fail at night and stop in a safe, lit place.", "Avoid riding at night without working headlights."],
    avoid: ["Replacing a fuse with a higher-rated one or with wire", "Riding at night without headlights or indicators"],
    ask: ["Which fuse or wire failed?", "Why did it fail?"],
    steps: ["Check the fuses and relays.", "Check connectors and earth points.", "Test bulbs/LEDs and switches.", "Trace short circuits with a multimeter / test light."],
    tools: ["Fuse kit", "Multimeter and test light", "Common bulbs", "Connectors and insulation tape"],
    keywords: ["light", "bulb", "horn", "indicator", "wiring", "fuse", "electric", "current", "short circuit"],
  },
  {
    label: "Clutch / Gear",
    urgency: "medium",
    safe: false,
    causes: {
      two_wheeler: [
        ["Clutch cable loose or broken", 40, "The lever goes slack or gears will not change."],
        ["Worn clutch plates (slipping)", 30, "The engine revs but the bike does not pick up speed."],
        ["Gear linkage loose", 20, "The gear lever moves but gears do not engage."],
        ["Old or low gear oil", 10, "Hard gear changes and noise."],
      ],
      default: [
        ["Worn clutch plate / pressure plate", 35, "Slipping, burning smell, poor pick-up."],
        ["Clutch hydraulic leak (master / slave cylinder)", 25, "The pedal goes to the floor."],
        ["Gear linkage cable fault", 25, "Gears are hard to select or slip out."],
        ["Low gearbox oil", 15, "Grinding and whining noises."],
      ],
    },
    cost: { cycle_toto: [100, 800], two_wheeler: [100, 2500], four_wheeler: [500, 12000], heavy_vehicle: [1500, 20000] },
    doNow: ["If the clutch cable broke, do not force the gears.", "Stop if the gears grind loudly."],
    avoid: ["Forcing gears without the clutch", "Riding a slipping clutch for long distances"],
    ask: ["Is it the cable or the clutch plates?", "Can it be fixed on the spot or does it need the workshop?"],
    steps: ["Check clutch free play and the cable / hydraulics.", "Check the gear linkage.", "Check the gear-oil level.", "Road-test for slipping."],
    tools: ["Clutch cables", "Linkage bushes", "Gear oil", "Hydraulic fluid"],
    keywords: ["clutch", "gear", "gearbox", "gear nahi", "gear lag"],
  },
  {
    label: "Strange Noise",
    urgency: "medium",
    safe: true,
    causes: {
      default: [
        ["Loose body part or heat shield", 30, "Rattling over bumps."],
        ["Worn brake pads", 20, "Squeal or grinding while braking."],
        ["Wheel bearing or suspension wear", 20, "Humming that grows with speed or knocking over bumps."],
        ["Exhaust leak", 15, "Loud, popping exhaust sound."],
        ["Engine knocking (low or old oil)", 15, "Metallic knocking from the engine."],
      ],
    },
    cost: { cycle_toto: [50, 800], two_wheeler: [100, 1500], four_wheeler: [300, 6000], heavy_vehicle: [500, 8000] },
    doNow: ["Notice when the noise happens: braking, turning, accelerating or at idle — tell the mechanic.", "If it is a loud engine knock, stop and check the engine oil."],
    avoid: ["Driving fast with a grinding or knocking noise"],
    ask: ["Where exactly is the noise coming from?", "Is it safe to keep riding until a full service?"],
    steps: ["Road-test and locate the noise.", "Check brakes, wheel bearings and suspension.", "Check the exhaust and heat shields.", "Check engine oil level and condition."],
    tools: ["Basic tool kit", "Mechanic's stethoscope", "Jack and stands", "Clamps and zip ties"],
    keywords: ["noise", "sound", "awaz", "awaaz", "aawaz", "khat", "khit", "shabd", "shobdo", "knocking", "rattle"],
  },
  {
    label: "Oil / Fluid Leak",
    urgency: "high",
    safe: false,
    causes: {
      default: [
        ["Engine oil leak (gasket, seal or drain plug)", 40, "Black/brown drops under the engine."],
        ["Coolant leak (hose or radiator)", 25, "Green/pink sweet-smelling liquid."],
        ["Brake fluid leak", 15, "Clear/yellow slippery fluid near a wheel — dangerous."],
        ["Fuel leak", 10, "Smell of petrol/diesel — dangerous."],
        ["Gear oil leak", 10, "Thick oil near the gearbox."],
      ],
    },
    cost: { cycle_toto: [100, 800], two_wheeler: [100, 1500], four_wheeler: [300, 5000], heavy_vehicle: [500, 7000] },
    doNow: [
      "Look at the colour: black/brown = engine oil, green/pink = coolant, clear/yellow near the wheels = brake fluid, petrol smell = fuel.",
      "If brake fluid or fuel is leaking, do not drive.",
    ],
    avoid: ["Driving with a brake-fluid or fuel leak", "Running the engine with very low oil"],
    ask: ["Which fluid is leaking and from where?", "Is it safe to drive to the workshop?"],
    steps: ["Identify the fluid by colour and smell.", "Find the source (gasket, hose, drain plug, seals).", "Top up and fix temporarily if safe.", "Advise a workshop repair if needed."],
    tools: ["Engine oil and coolant for top-up", "Gaskets and hose clamps", "Drain plug washers", "Leak-detection dye (optional)"],
    keywords: ["leak", "tapak", "tapakna", "oil gir", "pani gir", "girche", "porche", "coolant", "mobil"],
  },
  {
    label: "Key Lost / Lockout",
    urgency: "low",
    safe: true,
    causes: {
      default: [
        ["Key locked inside or lost", 60, "The most common lockout."],
        ["Key chip / immobiliser not recognised", 25, "The engine cranks but will not start with this key."],
        ["Ignition lock jammed", 15, "The key will not turn."],
      ],
    },
    cost: { cycle_toto: [200, 1000], two_wheeler: [300, 1500], four_wheeler: [500, 8000], heavy_vehicle: [800, 6000] },
    doNow: ["Keep your RC and photo ID ready — the mechanic must check that you own the vehicle.", "Check if a spare key is available at home."],
    avoid: ["Forcing the lock with a screwdriver"],
    ask: ["Can a duplicate key be made on the spot?", "Does the key need chip programming?"],
    steps: ["Verify ownership (RC + photo ID) before opening any vehicle.", "Open with lockout tools without damage.", "Cut / program a duplicate key if needed."],
    tools: ["Lockout tool set", "Key duplication kit", "Transponder programmer (cars)"],
    keywords: ["key", "chabi", "chaabi", "chabbi", "chaabhi", "lock", "lockout", "chabi kho"],
  },
  {
    label: "Accident / Towing",
    urgency: "high",
    safe: false,
    causes: {
      default: [
        ["Collision damage that needs inspection or towing", 70, "Bent parts, leaks or wheel alignment problems after a hit."],
        ["Vehicle immobilised (not repairable on the spot)", 30, "Needs to be taken to a workshop."],
      ],
    },
    cost: { cycle_toto: [300, 1500], two_wheeler: [500, 1800], four_wheeler: [1500, 4500], heavy_vehicle: [3000, 12000] },
    doNow: [
      "If anyone is hurt, call 112 (emergency) or 108 (ambulance) first.",
      "Switch on the hazard lights and move people away from traffic.",
      "Take photos of the vehicles and the place for insurance.",
    ],
    avoid: ["Moving an injured person unless there is danger of fire", "Driving a vehicle that is leaking fluids after a crash"],
    ask: ["Can the vehicle be driven or does it need towing?", "Which workshop can take it?"],
    steps: ["Make the area safe (hazards, triangle).", "Check for fluid leaks and wheel/steering damage.", "Arrange towing if the vehicle cannot be driven safely."],
    tools: ["Tow rope / tow belt or flatbed arrangement", "Warning triangle", "First-aid kit"],
    keywords: ["accident", "takkar", "takar", "dhakka", "crash", "tow", "towing", "durghatna", "lag gaya"],
  },
];

const EMERGENCY_WORDS = ["fire", "aag", "agun", "blood", "khoon", "injur", "ghayal", "hurt", "chot", "unconscious", "behosh", "burning smell"];

const FIRST_NAME_FOR = (label: string) => KB.find((k) => k.label === label);

export function detectTags(text: string): string[] {
  const t = ` ${text.toLowerCase()} `;
  const found: string[] = [];
  for (const k of KB) {
    if (k.keywords.some((w) => t.includes(w))) found.push(k.label);
  }
  return found;
}

function causesFor(k: IssueKnowledge, category: Category): [string, number, string][] {
  return k.causes[category] ?? k.causes.default ?? Object.values(k.causes)[0] ?? [];
}

const URGENCY_RANK: Record<Urgency, number> = { low: 0, medium: 1, high: 2, emergency: 3 };

export function diagnose(input: {
  category: Category;
  vehicleName: string;
  issueTags: string[];
  description: string;
  mode: "customer" | "mechanic";
}): AssistResult {
  const detected = detectTags(input.description);
  const tags = Array.from(new Set([...input.issueTags.filter((t) => t !== "Other"), ...detected]))
    .filter((t) => FIRST_NAME_FOR(t));
  const issues = (tags.length ? tags : ["Won't Start"]).map((t) => FIRST_NAME_FOR(t)!).slice(0, 3);
  const primary = issues[0];
  const lower = input.description.toLowerCase();
  const emergency = EMERGENCY_WORDS.some((w) => lower.includes(w));

  // Merge causes: primary issue weighted fully, others at half weight.
  const merged = new Map<string, Cause>();
  issues.forEach((k, i) => {
    for (const [title, p, explanation] of causesFor(k, input.category)) {
      const weight = i === 0 ? 1 : 0.5;
      const prev = merged.get(title);
      merged.set(title, { title, explanation, probability: (prev?.probability ?? 0) + p * weight });
    }
  });
  const top = [...merged.values()].sort((a, b) => b.probability - a.probability).slice(0, 4);
  const total = top.reduce((s, c) => s + c.probability, 0) || 1;
  const likely = top.map((c) => ({ ...c, probability: Math.max(5, Math.round((c.probability / total) * 100)) }));

  let urgency = issues.reduce<Urgency>((u, k) => (URGENCY_RANK[k.urgency] > URGENCY_RANK[u] ? k.urgency : u), "low");
  if (emergency) urgency = "emergency";
  const safe = !emergency && issues.every((k) => k.safe);

  const [pMin, pMax] = primary.cost[input.category];
  const extraMax = issues.slice(1).reduce((s, k) => s + k.cost[input.category][1] * 0.5, 0);
  const doNow = [
    ...(emergency ? ["Call 112 (emergency) or 108 (ambulance) right now if anyone is hurt or there is fire/smoke."] : []),
    ...issues.flatMap((k) => k.doNow),
  ];

  const issueText = issues.map((k) => k.label.toLowerCase()).join(" + ");
  return {
    summary: emergency
      ? `Safety first: this sounds like an emergency. Get to a safe place and call 112. A mechanic can then help with the ${issueText}.`
      : `Most likely ${likely[0]?.title.toLowerCase() ?? issueText} on your ${input.vehicleName}. ${safe ? "It is usually safe to wait for the mechanic at the roadside." : "Please don't ride or drive until a mechanic checks it."}`,
    urgency,
    safe_to_ride: safe,
    likely_causes: likely,
    suggested_issue_tags: issues.map((k) => k.label),
    estimated_cost: {
      min_inr: pMin,
      max_inr: Math.round((pMax + extraMax) / 50) * 50,
      note: "Typical Durgapur labour + parts price. The mechanic confirms the final price before starting.",
    },
    do_now: Array.from(new Set(doNow)).slice(0, 5),
    avoid: Array.from(new Set(issues.flatMap((k) => k.avoid))).slice(0, 4),
    questions_for_mechanic: Array.from(new Set(issues.flatMap((k) => k.ask))).slice(0, 4),
    diagnostic_steps: input.mode === "mechanic" ? Array.from(new Set(issues.flatMap((k) => k.steps))).slice(0, 8) : [],
    tools_and_parts: input.mode === "mechanic" ? Array.from(new Set(issues.flatMap((k) => k.tools))).slice(0, 8) : [],
  };
}
