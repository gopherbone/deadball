// Vite's `?raw` imports (file contents as a string), used to read playdate/source/pdxinfo.
declare module "*?raw" {
  const text: string;
  export default text;
}
