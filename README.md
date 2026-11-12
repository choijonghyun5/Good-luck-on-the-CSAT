# 우리의 겨울, 우리의 소원 — 설정 순서
1. supabase.com 프로젝트 생성 → SQL Editor에 `schema.sql` 전체 실행
2. Authentication > Providers > Email: **Sign ups 비활성화** (관리자 계정은 수동 생성)
3. Authentication > Users > Add user 로 관리자 이메일/비밀번호 생성 후 SQL Editor에서:
   `insert into public.admins select id from auth.users where email='관리자@이메일';`
4. Project Settings > API 의 URL, anon(publishable) 키를 `config.js`에 입력 (service_role 키 금지)
5. GitHub에 올리고 Vercel에서 Import (Framework: Other, 빌드 없음) → 배포 URL 확인
6. `config.js`의 `site`, `index.html`의 og:image URL의 `YOUR-SITE.vercel.app`을 실제 URL로 교체 후 재배포
7. 관리자 페이지: `/admin` (로그인 + RLS로 보호)
