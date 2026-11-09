# Kindle

1. Create a project at supabase.com, open SQL Editor, paste `schema.sql`, run it.
2. Put your Project URL and anon key at the top of `api.js` (Project Settings > API). Never use the service_role key.
3. Authentication > Providers: keep Email on, and turn on "Confirm email" before launch.
4. Push this folder to a GitHub repo: Settings > Pages > Deploy from branch (main, root).
5. In Supabase: Authentication > URL Configuration, add your GitHub Pages link as the Site URL.
