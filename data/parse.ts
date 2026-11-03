// EXAMPLE
// {
//   id: "vegan-1",
//   diet: "vegan",
//   name: "Vegan Broccoli Soup Recipe",
//   cuisine: "american",
//   protein: 103.83,
//   carbs: 82.54,
//   fat: 139.3,
//   addedBy: "Your Full Name",
// };

// (Diet_type,
//   Recipe_name,
//   Cuisine_type,
//   Protein(g),
//   Carbs(g),
//   Fat(g),
//   Extraction_day,
//   Extraction_time);

import { parse } from "jsr:@std/csv";
const fileContent = await Deno.readTextFile("./All_Diets.csv");
const fileData = parse(fileContent, { skipFirstRow: true, strip: true });

const MAPPING: Record<string, string> = {
  Diet_type: "diet",
  Recipe_name: "name",
  Cuisine_type: "cuisine",
  "Protein(g)": "protine",
  "Carbs(g)": "carbs",
  "Fat(g)": "fat",
};

const mapToJson = (record: Record<string, string>) => {
  const output: Record<string, string> = {};
  for (const key of Object.keys(record)) {
    const mappedKey = MAPPING[key];

    if (!mappedKey) break;

    output[mappedKey] = record[key];
  }

  return output;
};

const data: Record<string, string>[] = [];

for (const row of fileData) {
  data.push(mapToJson(row));
}

const encoder = new TextEncoder();

const encoded = encoder.encode(JSON.stringify(data));

Deno.writeFile("recipies.json", encoded);
