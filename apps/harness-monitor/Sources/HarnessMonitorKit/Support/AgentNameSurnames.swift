import Foundation

enum AgentNameSurnames {
  static func codex(_ rng: inout some RandomNumberGenerator) -> String {
    if Bool.random(using: &rng) {
      return codexReal.randomElement(using: &rng) ?? "Maxwell"
    }
    let prefix = codexXRoots.randomElement(using: &rng) ?? "Fox"
    let suffix = englishSurnameSuffixes.randomElement(using: &rng) ?? "worth"
    return prefix + suffix
  }

  static func claude(_ rng: inout some RandomNumberGenerator) -> String {
    if Int.random(in: 0..<3, using: &rng) == 0 {
      return claudeReal.randomElement(using: &rng) ?? "Carter"
    }
    let prefix = cSurnamePrefixes.randomElement(using: &rng) ?? "Crisp"
    let suffix = englishSurnameSuffixes.randomElement(using: &rng) ?? "worth"
    return prefix + suffix
  }

  static func gemini(_ rng: inout some RandomNumberGenerator) -> String {
    if Int.random(in: 0..<3, using: &rng) == 0 {
      return geminiReal.randomElement(using: &rng) ?? "Garcia"
    }
    let prefix = gSurnamePrefixes.randomElement(using: &rng) ?? "Glad"
    let suffix = englishSurnameSuffixes.randomElement(using: &rng) ?? "stone"
    return prefix + suffix
  }

  static func robot(_ rng: inout some RandomNumberGenerator) -> String {
    let prefix = robotRoots.randomElement(using: &rng) ?? "Servo"
    let suffix = robotSuffixes.randomElement(using: &rng) ?? "tron"
    return prefix + suffix
  }

  static func rasta(_ rng: inout some RandomNumberGenerator) -> String {
    let prefix = rastaRoots.randomElement(using: &rng) ?? "Irie"
    let suffix = rastaSuffixes.randomElement(using: &rng) ?? "man"
    return prefix + suffix
  }

  static func opencode(_ rng: inout some RandomNumberGenerator) -> String {
    if Int.random(in: 0..<3, using: &rng) == 0 {
      return opencodeReal.randomElement(using: &rng) ?? "Carter"
    }
    let prefix = opencodeCPrefixes.randomElement(using: &rng) ?? "Cobble"
    let suffix = englishSurnameSuffixes.randomElement(using: &rng) ?? "field"
    return prefix + suffix
  }

  static let codexReal: [String] = [
    "Maxwell", "Knox", "Lennox", "Maddox", "Paxton", "Wilcox", "Hendrix",
    "Dixon", "Saxon", "Foxworth", "Croxton", "Buxton", "Sexton", "Roxburgh",
    "Truex", "Wexler", "Faux", "Coxen", "Roxby", "Saxby", "Drax", "Hexham",
    "Baxendale", "Plaxton", "Coxworthy", "Fairfax",
    "Roxas", "Vaux", "Paxon", "Foxley", "Cox", "Foxx",
  ]

  static let codexXRoots: [String] = [
    "Fox", "Cox", "Pax", "Lex", "Max", "Knox", "Rex", "Sax", "Nix", "Crox",
    "Trux", "Brux", "Zax", "Vex", "Hex", "Dax", "Wax", "Mox", "Bix",
    "Lux", "Quax", "Pix", "Tux", "Rax", "Drax", "Phlax", "Klyx", "Skax",
  ]

  static let claudeReal: [String] = [
    "Carter", "Clark", "Collins", "Cooper", "Coleman", "Cox", "Crawford",
    "Curtis", "Chambers", "Castro", "Carpenter", "Cole", "Campbell",
    "Cooke", "Cunningham", "Castillo", "Cruz", "Caldwell", "Calhoun",
    "Cleveland", "Crockett", "Cromwell", "Cantrell", "Cervantes",
    "Chen", "Conrad", "Conway", "Cook", "Coyle", "Craig", "Crane",
    "Crosby", "Cuevas", "Cullen", "Cummings", "Curry", "Cardenas",
    "Carrillo", "Carson", "Cash", "Cherry", "Christie", "Coffey",
    "Cohen", "Conley", "Connor", "Cordova", "Cortez", "Costello",
    "Cotton",
  ]

  static let cSurnamePrefixes: [String] = [
    "Crisp", "Cobble", "Crock", "Carr", "Cald", "Cliff", "Cool", "Crow",
    "Cope", "Camp", "Cork", "Cant", "Crest", "Cumb", "Chal", "Chand",
    "Cardi", "Coast", "Castel", "Chap", "Chase", "Crew", "Cresh",
    "Crinkle", "Chester", "Camel", "Crum", "Cuddle", "Copper", "Crispy",
    "Cackleb", "Crab", "Cinder", "Cobb", "Crackleb", "Cresc",
    "Crinkly", "Crown", "Cromer", "Curfew", "Crispwood", "Cyder",
  ]

  static let geminiReal: [String] = [
    "Garcia", "Gardner", "Gibson", "Graham", "Grant", "Greene", "Griffin",
    "Gross", "Garrett", "Gibbs", "Goodwin", "Glenn", "Gallagher",
    "Gates", "Gay", "Gilbert", "Giles", "Gill", "Gilmore", "Glover",
    "Goff", "Gonzales", "Goodman", "Gordon", "Gould", "Graves", "Gray",
    "Greer", "Gregg", "Gregory", "Griffith", "Grimes", "Guerra",
    "Guthrie", "Garner", "Galloway", "Gilliam", "Gladstone",
  ]

  static let gSurnamePrefixes: [String] = [
    "Glad", "Gar", "Gold", "Grim", "Gray", "Green", "Glen", "Goss",
    "Gunn", "Garr", "Gibb", "Gable", "Gat", "Gif", "Glim",
    "Goose", "Gram", "Gran", "Grub", "Grump", "Gurg", "Galleo",
    "Gladwyn", "Goggle", "Goodfellow", "Greenleaf", "Grizzle", "Gusty",
    "Galsworth", "Glisten", "Gabriel", "Glimmer",
  ]

  static let englishSurnameSuffixes: [String] = [
    "worth", "ton", "ley", "by", "ford", "bury", "ham", "stone",
    "field", "bridge", "wood", "leigh", "ridge", "smith", "well",
    "beck", "berg", "bourne", "mark", "shire", "burgh", "haven",
    "moor", "dale", "holt", "thorpe", "wick", "side", "burn",
  ]

  static let robotRoots: [String] = [
    "Servo", "Cog", "Gear", "Wire", "Bolt", "Volt", "Piston", "Sprocket",
    "Capacit", "Microvolt", "Datacore", "Nullbyte", "Logicgate", "Tron",
    "Clank", "Iron", "Quantum", "Nano", "Neuro", "Cyber", "Diode",
    "Resistor", "Transistor", "Nullspace", "Bytefield", "Anode",
    "Cathode", "Buffer", "Cache", "Compiler", "Daemon", "Driver",
    "Encoder", "Fuse", "Gate", "Heuristic", "Index", "Junction",
    "Kernel", "Lambda", "Matrix", "Nexus", "Octet", "Packet",
    "Quark", "Rotor", "Stator", "Turbo", "Uplink", "Vector",
    "Watt", "Xenon", "Yotta", "Zenith", "Pulse", "Wave", "Spark",
    "Photon", "Plasma", "Magneto", "Lattice", "Rivet", "Galv",
    "Voltaic", "Mech", "Auto", "Ohm",
  ]

  static let robotSuffixes: [String] = [
    "omatic", "worth", "tron", "ix", "bot", "byte", "core", "berg",
    "son", "ovich", "drive", "field", "engine", "prime", "unit",
    "ward", "soft", "hammer", "zilla", "logic", "matic", "ware",
    "punk", "graph", "stein", "scope", "cluster", "machinist",
    "morph", "nautics", "synth", "mind", "frame",
  ]

  static let rastaRoots: [String] = [
    "Irie", "Jah", "Zion", "Lion", "Iyah", "Roots", "Ras", "Bredren",
    "Empress", "Selass", "Negus", "Ites", "Levi", "Marcus", "Coral",
    "Bingi", "Higher", "Light", "Ingle", "Ireheart", "Rootsman",
    "Niyah", "Bobo", "Jahmar", "Jahmir", "Lionsbridge", "Kingly",
    "Ireland", "Iration", "Inity", "Iyaric", "Iverflow", "Rastaman",
    "Reggie", "Idren", "Iya", "Earthy", "Sunsplash",
  ]

  static let rastaSuffixes: [String] = [
    "man", "bless", "wood", "heart", "bridge", "son", "field",
    "ville", "heights", "dale", "hill", "worth", "bright", "ster",
    "ling", "sound", "vibes", "stand", "rise", "step", "talk",
    "song", "skip", "leaf",
  ]

  static let opencodeReal: [String] = [
    "Cleary", "Crosby", "Coffey", "Cabrera", "Camacho", "Cardenas",
    "Carey", "Carrillo", "Carrington", "Carvalho", "Casey", "Cassidy",
    "Cavanaugh", "Childers", "Chong", "Cisneros", "Clarkson", "Cleveland",
    "Cliburn", "Coffin", "Coker", "Conklin", "Conner", "Cooley",
    "Coombs", "Coons", "Cope", "Corbett", "Corcoran", "Cornell",
    "Cosgrove", "Cotter", "Crowley", "Cushing", "Custer", "Carmichael",
    "Childress", "Choate",
  ]

  static let opencodeCPrefixes: [String] = [
    "Clover", "Cold", "Crest", "Cobble", "Cunning", "Cramp", "Crock",
    "Crow", "Cherr", "Chamber", "Cant", "Clatter", "Cumber", "Coal",
    "Cedar", "Castle", "Cliff", "Cross", "Coast", "Cape", "Cavern",
    "Cinder", "Cipher", "Citadel", "Coppermin", "Cottage", "Crescent",
    "Cromer", "Crystal", "Cypress", "Conclave", "Constellation",
    "Compass", "Cardinal",
  ]
}
