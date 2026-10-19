-- GENERATED from packages/sim/src/names.ts and images/faces/faces.json (pennant/data.lua).
-- Name pools and the face bank's male faces by age class. Regenerate rather than hand-edit.

PennantData = PennantData or {}
local D = PennantData

D.FIRST = {
  "Archie", "Moose", "Clem", "Walt", "Eddie", "Lou", "Frank", "Joe", "Harry", "Tom", "Bill", "Ray",
  "Earl", "Gus", "Hank", "Otis", "Vern", "Cal", "Rube", "Dutch", "Sal", "Mickey", "Buck", "Dale",
  "Russ", "Leon", "Mel", "Stan", "Floyd", "Ike", "Jimmy", "Tony", "Marty", "Wes", "Al", "Bert", "Cy",
  "Duke", "Emil", "Fritz", "Gil", "Herb", "Irv", "Jack", "Kip", "Lefty", "Milo", "Ned", "Ollie",
  "Pete", "Quincy", "Rollie", "Sid", "Ted", "Ulysses", "Virgil", "Wally", "Zeke", "Andre", "Benny",
  "Carlos", "Darnell", "Ernesto", "Felix", "Hector", "Isaiah", "Jesus", "Kenji", "Luis", "Manny",
  "Nate", "Orlando", "Pedro", "Reggie", "Satchel", "Tito", "Vic", "Willie", "Yogi", "Hideo", "Minnie",
  "Chico", "Lonnie", "Dwight", "Rico",
}
D.LAST = {
  "Dunphy", "Mullane", "Whitlock", "Carrigan", "Moran", "Kessler", "Feeney", "Haldane", "McCann",
  "Okafor", "Ruggles", "Pruitt", "Vance", "Toomey", "Sayre", "Haskins", "Orr", "Ames", "Delahanty",
  "Brannigan", "Kowalski", "Szymanski", "Lindqvist", "Abernathy", "Barrow", "Coogan", "Devlin",
  "Esposito", "Fitzgerald", "Gallagher", "Hennessy", "Ingram", "Jablonski", "Kavanagh", "Lomax",
  "Mahoney", "Novak", "O'Rourke", "Pappas", "Quigley", "Rafferty", "Shaughnessy", "Tierney",
  "Underhill", "Vukovich", "Wojcik", "Yablonski", "Zaleski", "Alvarez", "Batista", "Cruz", "Delgado",
  "Escobar", "Fuentes", "Guerrero", "Herrera", "Ibarra", "Jimenez", "Luna", "Morales", "Navarro",
  "Ortega", "Paredes", "Quintana", "Reyes", "Salazar", "Tanaka", "Ueda", "Watanabe", "Yamamoto",
  "Washington", "Jefferson", "Gibson", "Leonard", "Paige", "Charleston", "Dandridge", "Irvin",
  "Pettibone", "Crabtree", "Gooch", "Puckett", "Swindell", "Bumgardner", "Pinkerton", "Ludlow",
  "Huckaby", "Stottlemyre", "Grimsley", "Wiggins", "Tubbs", "Fogarty", "Pickles",
}
D.NICKS = {
  "Moose", "Lefty", "Specs", "Dutch", "Pops", "Kid", "Big Train", "Slats", "Cracker", "Sudsy",
  "Hambone", "Doc", "Spider", "Chief", "Gabby", "Peaches", "Boots", "Smokey", "Tank", "Wheels",
  "Noodles", "Sarge", "Junior", "Bubba", "Rabbit", "Stinky", "Red", "Whitey", "Ducky", "Bones", "Tiny",
  "Mule", "Preacher", "Hollywood", "Jitters",
}
D.FARM_CITIES = {
  "Ashby", "Brockton", "Cairo", "Dunmore", "Elmira", "Fort Pike", "Gilead", "Hatboro", "Ironton",
  "Joliet", "Keokuk", "Laramie", "Macon", "Natchez", "Oneida", "Paducah", "Quincy", "Rome", "Sedalia",
  "Tullahoma", "Utica", "Vicksburg", "Wheeling", "Yazoo", "Zanesville", "Bristol", "Cumberland",
  "Durango",
}
D.FARM_NAMES = {
  "Mudcats", "Bootleggers", "Haymakers", "Millers", "Tobacconists", "Rivermen", "Coal Barons", "Bees",
  "Owls", "Ducks", "Lumberjacks", "Tanners", "Brewers", "Crawdads", "Possums", "Locomotives",
  "Typewriters", "Pickles", "Grasshoppers", "Hornets", "Smelters", "Soapmakers", "Prospectors",
  "Whalers", "Clamdiggers",
}
D.FACES_YOUNG = {
  0, 1, 2, 11, 15, 19, 29, 52, 64, 71, 74, 79, 83, 84, 95, 97, 103, 109, 111, 125, 135, 141, 144, 158,
  165, 167, 172, 193, 199, 223, 226, 238, 269, 277, 278, 302, 324, 330, 341, 351, 359, 371, 386, 415,
  420, 429, 475, 493, 501, 514, 557, 583,
}
D.FACES_ADULT = {
  3, 4, 6, 7, 8, 9, 10, 16, 18, 20, 21, 23, 24, 25, 28, 30, 32, 33, 34, 35, 36, 38, 39, 41, 43, 45, 46,
  48, 49, 50, 51, 54, 57, 59, 62, 65, 66, 68, 69, 70, 72, 75, 76, 77, 80, 81, 86, 88, 92, 93, 98, 99,
  100, 102, 104, 106, 107, 115, 116, 117, 118, 119, 120, 121, 122, 123, 124, 126, 127, 132, 133, 134,
  136, 139, 142, 143, 145, 146, 147, 148, 151, 152, 153, 154, 155, 156, 162, 168, 173, 175, 178, 181,
  183, 184, 187, 188, 190, 191, 192, 196, 197, 200, 201, 202, 203, 205, 206, 208, 209, 210, 211, 212,
  213, 214, 215, 220, 222, 224, 225, 227, 228, 231, 232, 233, 234, 235, 236, 237, 239, 240, 242, 246,
  247, 248, 249, 250, 253, 254, 255, 256, 257, 258, 259, 260, 261, 263, 264, 265, 266, 270, 271, 272,
  273, 276, 279, 281, 282, 283, 284, 285, 286, 287, 289, 290, 291, 292, 293, 294, 296, 297, 300, 301,
  303, 304, 305, 307, 308, 310, 313, 314, 317, 319, 320, 321, 322, 323, 325, 326, 327, 328, 329, 333,
  335, 338, 339, 340, 342, 343, 344, 347, 349, 352, 353, 357, 363, 366, 367, 373, 374, 376, 377, 378,
  379, 381, 382, 390, 392, 394, 395, 397, 399, 401, 407, 408, 410, 412, 413, 416, 417, 418, 419, 423,
  424, 425, 427, 432, 433, 434, 435, 436, 437, 438, 441, 442, 444, 445, 447, 448, 449, 450, 451, 453,
  455, 459, 461, 463, 465, 466, 468, 469, 472, 473, 476, 477, 478, 479, 480, 481, 482, 484, 485, 486,
  491, 492, 494, 495, 497, 500, 503, 504, 505, 506, 508, 510, 516, 522, 526, 527, 529, 530, 532, 536,
  537, 538, 540, 541, 542, 545, 550, 554, 555, 556, 561, 562, 563, 564, 567, 572, 575, 577, 587, 589,
  590, 592, 594, 595, 596, 597, 598,
}
D.FACES_OLD = {
  22, 42, 53, 60, 61, 63, 78, 89, 110, 112, 113, 138, 161, 179, 185, 207, 229, 241, 251, 252, 268, 275,
  288, 318, 334, 337, 355, 356, 358, 369, 383, 388, 398, 400, 411, 426, 430, 457, 464, 467, 483, 487,
  509, 528, 552, 553, 582, 584, 588,
}
