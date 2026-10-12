"""Browser test of the REGULENTA app against the LOCAL stack (stack.sh). Fixture data only; nothing leaves this machine.
Run: python3 supabase/tests/ui/ui_test.py   (screenshots go to $SHOTS or /tmp/regulenta-ui-shots)
"""
import base64, hashlib, hmac, json, os, subprocess, sys, time
from playwright.sync_api import sync_playwright, expect

APP = 'http://localhost:5199'
SECRET = b'local-ui-test-secret-0123456789abcdef'
SHOTS = os.environ.get('SHOTS', '/tmp/regulenta-ui-shots'); os.makedirs(SHOTS, exist_ok=True)
PSQL = ['psql', '-h', '/var/tmp/regulenta-pg', '-p', '54329', '-U', 'postgres', '-d', 'regulenta_ui', '-Atq', '-c']
results = []

def b64(d): return base64.urlsafe_b64encode(d).rstrip(b'=').decode()
def jwt(sub, email):
    now = int(time.time())
    head = b64(json.dumps({'alg': 'HS256', 'typ': 'JWT'}).encode())
    body = b64(json.dumps({'sub': sub, 'email': email, 'role': 'authenticated', 'aud': 'authenticated', 'iat': now, 'exp': now + 86400}).encode())
    sig = b64(hmac.new(SECRET, f'{head}.{body}'.encode(), hashlib.sha256).digest())
    return f'{head}.{body}.{sig}'
def session(sub, email):
    now = int(time.time())
    return json.dumps({'access_token': jwt(sub, email), 'token_type': 'bearer', 'expires_in': 86400, 'expires_at': now + 86400,
                       'refresh_token': 'local-test', 'user': {'id': sub, 'email': email, 'aud': 'authenticated', 'role': 'authenticated',
                                                                  'app_metadata': {}, 'user_metadata': {}}})
def sql(q): return subprocess.run(PSQL + [q], capture_output=True, text=True, check=True).stdout.strip()

def check(name, fn):
    try:
        fn(); results.append((True, name, ''))
    except Exception as e:
        results.append((False, name, str(e).splitlines()[0][:300]))

def login(browser, sub, email):
    ctx = browser.new_context(viewport={'width': 1360, 'height': 900})
    ctx.add_init_script(f"localStorage.setItem('sb-localhost-auth-token', {json.dumps(session(sub, email))})")
    page = ctx.new_page()
    errors = []
    page.on('pageerror', lambda e: errors.append(str(e)))
    page.goto(APP); return ctx, page, errors

with sync_playwright() as pw:
    browser = pw.chromium.launch(executable_path='/opt/pw-browsers/chromium-1194/chrome-linux/chrome')
    ctx, page, errs = login(browser, 'a1000000-0000-0000-0000-000000000001', 'owner@firma.test')

    def s01():
        expect(page.get_by_text('Set up your workspace')).to_be_visible(timeout=10000)
        page.get_by_label('Name').fill('Firm A (UI test)'); page.get_by_role('button', name='Create workspace').click()
        expect(page.get_by_role('heading', name='Compliance overview')).to_be_visible(timeout=10000)
        page.screenshot(path=f'{SHOTS}/01-dashboard-empty.png')
    check('01 sign-in, create workspace, empty dashboard', s01)

    def s02():
        page.get_by_role('button', name='Companies').click(); page.get_by_role('button', name='+ Add').click()
        page.get_by_label('Legal name').fill('Kestrel Foods Pvt Ltd (UI test)'); page.get_by_label('CIN / LLPIN').fill('ABC123')
        page.get_by_role('button', name='Save', exact=True).click()
        expect(page.get_by_text('CIN must be 21 characters')).to_be_visible()
        page.get_by_label('CIN / LLPIN').fill('U74999HR2015PTC012345'); page.get_by_role('button', name='Save', exact=True).click()
        expect(page.get_by_role('heading', name='Kestrel Foods Pvt Ltd (UI test)')).to_be_visible()
    check('02 add company; invalid CIN rejected with a clear message', s02)

    def s03():
        page.get_by_role('button', name='Contacts').click()
        page.get_by_label('Full name').fill('Officer Test'); page.get_by_label('Email', exact=True).fill('officer@kestrel.test')
        page.get_by_label('Role').select_option('compliance_officer'); page.get_by_text('This person agreed to receive reminder emails').click()
        page.get_by_role('button', name='Add contact').click()
        expect(page.get_by_role('cell', name='officer@kestrel.test')).to_be_visible()
        page.screenshot(path=f'{SHOTS}/02-contacts.png')
    check('03 add an opted-in contact (starts unverified)', s03)

    def s04():
        page.get_by_role('button', name='Generate deadlines').click()
        page.locator('input[type=date]').first.fill('2026-10-01'); page.get_by_role('button', name='Preview').click()
        expect(page.get_by_text('Will create:')).to_be_visible()
        expect(page.locator('td', has_text='FX-LISTED').first).to_be_visible()
        expect(page.get_by_text('review required').first).to_be_visible()
        page.screenshot(path=f'{SHOTS}/03-preview.png')
        page.get_by_role('button', name='Save').filter(has_text='as proposed').click()
        expect(page.get_by_text('proposed deadline(s) saved')).to_be_visible()
        page.get_by_role('button', name='Activate all').click(); page.get_by_role('button', name='Yes').click()
        expect(page.get_by_text('deadline(s) activated')).to_be_visible()
        n = int(sql("select count(*) from obligations where lifecycle='active'"))
        assert n > 0, 'no active obligations in DB'
    check('04 preview → save proposed → activate (review-required rule not generated)', s04)

    def s05():
        page.get_by_role('button', name='Compliance', exact=True).click()
        page.locator('.list li').first.click()
        expect(page.get_by_text('Approved rule v1')).to_be_visible()
        page.get_by_role('button', name='Start preparing').click()
        page.get_by_role('button', name='Submit for review').click()
        page.get_by_role('button', name='Approve').click()
        expect(page.get_by_text('maker-checker')).to_be_visible()
        page.screenshot(path=f'{SHOTS}/04-obligation-maker-checker.png')
        assert sql("select count(*) from obligations where stage='in_review'") == '1'
    check('05 workflow buttons; submitter cannot approve (maker-checker shown)', s05)

    def s06():
        page.get_by_role('button', name='Reminders & recipients').click()
        page.get_by_text('Switch on email delivery for this organisation').click(); page.get_by_role('button', name='Save schedule').click()
        expect(page.get_by_text('Saved.')).to_be_visible()
        page.get_by_label('Person').select_option(label='owner@firma.test (owner)'); page.get_by_role('button', name='Add recipient').click()
        expect(page.get_by_text('Recipient added.')).to_be_visible()
        page.screenshot(path=f'{SHOTS}/05-settings.png')
        assert sql("select email_enabled from reminder_settings") == 't'
    check('06 switch on email; add a recipient', s06)

    def s07():
        sql("set role service_role; select generate_notification_events()")
        page.get_by_role('button', name='Dashboard').click()
        page.get_by_role('button', name='Notifications').click()
        expect(page.locator('.notes li').first).to_be_visible()
        page.screenshot(path=f'{SHOTS}/06-notifications.png')
        page.get_by_role('button', name='Mark all as read').click()
        expect(page.locator('.notes li.unread')).to_have_count(0)
        assert sql("select count(*) from notification_deliveries where channel='email' and status='queued'") != '0', 'no email queued'
    check('07 scheduler → notification centre; mark all read; email queued (not sent)', s07)

    def s08():
        page.get_by_role('button', name='Dashboard').click()
        due30 = sql("""select count(*) from obligations where lifecycle='active' and stage in ('initiated','preparing','in_review','approved','executed')
                       and due_date between (now() at time zone 'Asia/Kolkata')::date and (now() at time zone 'Asia/Kolkata')::date + 30""")
        tile = page.locator('.tile', has_text='Due in next 30 days').locator('.n')
        expect(tile).to_have_text(due30)
        appr = sql("select count(*) from obligations where stage='in_review'")
        expect(page.locator('.tile', has_text='Pending approvals').locator('.n')).to_have_text(appr)
        page.screenshot(path=f'{SHOTS}/07-dashboard.png')
    check('08 dashboard counts equal database counts', s08)
    owner_errors = list(errs)
    ctx.close()

    ctx, page, errs = login(browser, '99999999-0000-0000-0000-000000000009', 'reviewer@platform.test')
    def s09():
        page.get_by_role('button', name='Review queue').click()
        page.locator('.list li', has_text='FX-PENDING').click()
        expect(page.get_by_text('No primary-source evidence attached. This item cannot be approved.')).to_be_visible()
        expect(page.get_by_role('button', name='Approve rule')).to_be_disabled()
        page.screenshot(path=f'{SHOTS}/08-review.png')
    check('09 reviewer: item without evidence cannot be approved', s09)

    def s10():
        page.get_by_role('button', name='Regulatory intelligence').click()
        page.get_by_role('button', name='Log a publication').click()
        page.get_by_label('Authority').select_option(label='FIXT — Fixture Authority (test only)')
        page.get_by_label('Title').fill('FIXTURE amendment notification'); page.get_by_label('Official source URL').fill('https://example.invalid/amend')
        page.get_by_label('Existing rules affected (hold Ctrl / ⌘ to choose several)').select_option(label='FX-MONTHLY — Fixture monthly return')
        page.get_by_role('button', name='Log publication').click()
        page.locator('.list li', has_text='FIXTURE amendment notification').click()
        expect(page.get_by_text('Regulatory change impact report')).to_be_visible()
        expect(page.get_by_role('cell', name='FX-MONTHLY Fixture monthly return')).to_be_visible()
        page.screenshot(path=f'{SHOTS}/09-impact-report.png')
        assert sql("select count(*) from research_queue where status='new'") == '1'
    check('10 reviewer: log a publication → impact report lists affected rule', s10)

    def s11():
        page.get_by_role('button', name='Delivery health').click()
        expect(page.get_by_text('Scheduler runs')).to_be_visible()
        assert '@' not in page.locator('table').first.inner_text(), 'address exposed'
        page.screenshot(path=f'{SHOTS}/10-health.png')
    check('11 staff delivery health shows no recipient addresses', s11)

    def s12():
        page.set_viewport_size({'width': 400, 'height': 860}); page.get_by_role('button', name='Review queue').click()
        w = page.evaluate('document.documentElement.scrollWidth')
        assert w <= 400, f'horizontal scroll at phone width ({w}px)'
        page.screenshot(path=f'{SHOTS}/11-phone.png')
    check('12 phone width: no horizontal page scroll', s12)
    all_errors = owner_errors + errs
    check('13 no JavaScript errors in the browser', lambda: (_ for _ in ()).throw(AssertionError('; '.join(all_errors))) if all_errors else None)
    ctx.close(); browser.close()

for ok, name, detail in results: print(('PASS ' if ok else 'FAIL ') + name + ('' if ok else f'  -- {detail}'))
print(f"{sum(r[0] for r in results)} passed, {sum(not r[0] for r in results)} failed")
sys.exit(0 if all(r[0] for r in results) else 1)
