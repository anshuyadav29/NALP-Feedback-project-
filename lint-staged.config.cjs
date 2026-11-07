module.exports = {
  '**/*.{ts,tsx}': ['eslint --fix', 'prettier --write', () => 'tsc --noEmit'],
  '**/*.{js,jsx,json,css,md}': ['prettier --write'],
};
