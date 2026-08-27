import nextConfig from 'eslint-config-next';
const config = [
  ...nextConfig,
  { ignores: ['.next/**', '.open-next/**', 'coverage/**', '.audit/**'] }
];
export default config;