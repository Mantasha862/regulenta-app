# REGULENTA — Rule Verification Research (Round 1, 12 Oct 2026)

All 52 rules are pending (0 approved, 0 evidence records attached).
Status: 46 pending_review, 6 conflict.

## Research completed this round

### GST Rules (6 items: GST-031 to GST-036)
Source: RegisterKaro GST Calendar, CBIC notifications, CGST Act 2017.

| Key | Form | Verified due date | Schedule type | Source provision |
|-----|------|-------------------|---------------|-----------------|
| GST-031 | GSTR-1 (monthly) | 11th of following month | monthly_day {day: 11} | CGST Act s.37, CGST Rules r.59 |
| GST-031 | GSTR-1 (QRMP quarterly) | 13th of month after quarter end | after_period_end {period: quarter, days: 13, day_type: calendar} | CGST Act s.37, QRMP Notification |
| GST-032 | GSTR-3B (monthly) | 20th of following month | monthly_day {day: 20} | CGST Act s.39, CGST Rules r.61 |
| GST-032 | GSTR-3B (QRMP quarterly) | 22nd/24th of month after quarter (state-based) | after_period_end {period: quarter, days: 22, day_type: calendar} | CGST Act s.39 + state notification |
| GST-033 | CMP-08 | 18th of month after quarter end | after_period_end {period: quarter, days: 18, day_type: calendar} | CGST Act s.10, CGST Rules r.62 |
| GST-034 | GSTR-7 (TDS) | 10th of following month | monthly_day {day: 10} | CGST Act s.39(3), CGST Rules |
| GST-035 | GSTR-8 (TCS) | 10th of following month | monthly_day {day: 10} | CGST Act s.52, CGST Rules |
| GST-036 | GSTR-9 / GSTR-9C | 31 December of following FY | annual_fixed {day: 31, month: 12} | CGST Act s.44; GSTR-9 mandatory >₹2Cr, GSTR-9C >₹5Cr |

**Notes:**
- GSTR-1 QRMP threshold: ≤₹5 crore aggregate turnover (need to confirm from primary notification)
- GSTR-3B QRMP: 22nd for Cat A states, 24th for Cat B states (state grouping from CBIC notification)
- Due date extensions are notified separately each year; the base dates above are the statutory defaults

### SEBI LODR / PIT / SAST (13 items: SEBI-019 to SEBI-030)
Source: TaxGuru analysis of SEBI LODR Third Amendment Regulations 2024, notification dated 12-12-2024.

**Conflicts resolved:**
- **SEBI-028 Reg 7(3):** OMITTED w.e.f. 13 December 2024 — this rule should be marked as superseded/not applicable
- **SEBI-027 Reg 40(9):** Actually Reg 40(10) was omitted w.e.f. 13 December 2024 (the CS certificate requirement under Reg 40(9)); need primary gazette to confirm exact sub-regulation numbering
- **SEBI-023 Reg 29 prior intimation:** Changed to "at least 2 working days" (per June 2023 amendment, effective from gazette date); this resolves the 2-vs-5/11-day conflict

**Effective dates confirmed:**
- Most amendments: 13 December 2024
- Reg 13(3) quarterly complaints and Reg 27(2) CG report: 31 December 2024
- Reg 24A secretarial audit (peer review): 1 April 2025

| Key | Regulation | Due date / frequency | Schedule type | Status |
|-----|-----------|---------------------|---------------|--------|
| SEBI-019 | Reg 31 shareholding | Within 21 days from quarter end | after_period_end {period: quarter, days: 21, day_type: calendar} | Needs primary text |
| SEBI-020 | Reg 27(2) CG report | Within 21 days from quarter end (effective 31-12-2024) | after_period_end {period: quarter, days: 21, day_type: calendar} | Needs primary text |
| SEBI-021 | Reg 13(3) complaints | Within 21 days from quarter end (effective 31-12-2024) | after_period_end {period: quarter, days: 21, day_type: calendar} | Needs primary text |
| SEBI-022 | Reg 33 financial results | Within 45 days from quarter end (60 days for last quarter) | after_period_end {period: quarter, days: 45, day_type: calendar} | Needs primary text |
| SEBI-023 | Reg 29 prior intimation | At least 2 working days before board meeting | event_offset {anchor: board_meeting, days: 2, day_type: working, direction: before} | CONFLICT RESOLVED |
| SEBI-024 | Reg 30 + Sch III disclosures | Within 30 minutes / 24 hours of event | event_offset | Needs primary text |
| SEBI-025 | Reg 44(3) voting results | Within 2 working days of GM | event_offset {anchor: general_meeting, days: 2, day_type: working, direction: after} | Needs primary text |
| SEBI-026 | Reg 24A secretarial audit | Within 60 days of FY end | after_period_end {period: fy, days: 60, day_type: calendar} | Peer review effective 1-Apr-2025 |
| SEBI-027 | Reg 40(9) | LIKELY OMITTED (actually 40(10)) w.e.f. 13-12-2024 | — | Needs gazette for exact sub-reg |
| SEBI-028 | Reg 7(3) | OMITTED w.e.f. 13-12-2024 | — | Should be superseded |
| SEBI-029 | PIT Reg 7 | Within 2 trading days of crossing threshold | event_offset | Needs primary text |
| SEBI-030 | SAST Reg 30 | Various event-triggered deadlines | event_offset | Needs primary text |

### Labour (5 items: LAB-037 to LAB-041)
Source: Taxmann on EPF Scheme 2026, KPMG Flash News.

- **LAB-037 EPF:** EPF Scheme 2026 (G.S.R. 525(E), 29-06-2026) supersedes the 1952 scheme. Contribution due date needs the primary gazette — earlier scheme was 15th of following month. The queue still cites the 1952 scheme; must be updated.
- **LAB-038 ESI:** ESI (General) Regulations 1950, Reg 31 — contribution due by 15th of following month. Needs primary text.
- **LAB-039 Bonus:** Payment of Bonus Act 1965 s.19 — within 8 months of closing of accounting year. Needs primary text.
- **LAB-040 Gratuity:** Payment of Gratuity Act 1972 s.7 — within 30 days of it becoming payable. Event-triggered. Needs primary text.
- **LAB-041 State LWF/PT:** Per-state deadlines. CONFLICT remains — no single national date. Research done separately for major states.

### Companies Act & LLP (18 items: CA-001 to CA-018)
These are the highest volume. Key provisions from my training knowledge (need primary text confirmation):

| Key | Form | Known due date | Schedule type | Note |
|-----|------|---------------|---------------|------|
| CA-001 | AGM | Within 6 months of FY end (15 months for first AGM) | annual_fixed {day: 30, month: 9} | s.96 |
| CA-002 | AOC-4 | Within 30 days of AGM | event_offset {anchor: agm, days: 30} | CONFLICT: fee table unverified |
| CA-003 | MGT-7/7A | Within 60 days of AGM | event_offset {anchor: agm, days: 60} | CONFLICT: 7 vs 7A applicability |
| CA-004 | ADT-1 | Within 15 days of AGM | event_offset {anchor: agm, days: 15} | s.139 |
| CA-005 | DIR-3 KYC | 30 September (annual/triennial) | annual_fixed {day: 30, month: 9} | G.S.R. 943(E) triennial change |
| CA-006 | DPT-3 | 30 June annually | annual_fixed {day: 30, month: 6} | Deposit Rules r.16 |
| CA-007 | MSME-1 | Half-yearly (31 Oct, 30 Apr) | annual_dates {dates: ["04-30","10-31"]} | s.405 |
| CA-008 | Board meetings | Min 4 per FY, ≤120 days gap | manual {note: "4/year, max 120-day gap"} | s.173 |
| CA-017 | LLP Form 11 | 30 May annually | annual_fixed {day: 30, month: 5} | LLP Act s.35 |
| CA-018 | LLP Form 8 | 30 October annually | annual_fixed {day: 30, month: 10} | LLP Act s.34 |

### Income Tax (6 items: TAX-042 to TAX-047)
**ISSUE:** The queue mixes Income-tax Act 2025 and 1961 Act references. This must be resolved first.

| Key | Form | Known due date | Note |
|-----|------|---------------|------|
| TAX-042 | TDS payment | 7th of following month (30 Apr for March) | s.195 old / need 2025 Act equivalent |
| TAX-043 | TDS return | Quarterly: 31 Jul, 31 Oct, 31 Jan, 31 May | |
| TAX-044 | Form 16/16A | 15 June (16) / 15 days from TDS return (16A) | |
| TAX-045 | Advance tax | 15 Jun, 15 Sep, 15 Dec, 15 Mar | s.211 |
| TAX-046 | Tax audit + ITR | 30 Sep (audit), 31 Oct (ITR if audit) | s.44AB, s.139 |
| TAX-047 | 3CEB | 31 Oct (TP report) | s.92E |

### FEMA / RBI (5 items: FEMA-048 to FEMA-052)
Low-confidence dates; need RBI Master Directions.

| Key | Form | Known due date | Confidence |
|-----|------|---------------|------------|
| FEMA-048 | FC-GPR | Within 30 days of allotment | Medium |
| FEMA-049 | FC-TRS | Within 60 days of transfer | Medium |
| FEMA-050 | FLA | 15 July annually | Low |
| FEMA-051 | ECB-2 | Monthly, within 7 days | Low |
| FEMA-052 | APR | 31 December annually | Low |

## What's needed to complete verification

1. **Primary source PDFs** — I cannot access egazette.gov.in, mca.gov.in, indiacode.nic.in from here. Upload the originals and I'll extract exact provisions.
2. **Income-tax Act decision** — Are we using the 2025 Act or the 1961 Act? The queue must be consistent.
3. **EPF Scheme 2026 gazette** — Need to confirm the contribution due date (was 15th under 1952 scheme).
4. **SEBI gazette notification 12-12-2024** — Confirm exact sub-regulation numbers for Reg 40(9)/40(10) omission.

## Sources
- RegisterKaro GST Calendar: https://www.registerkaro.in/post/gst-compliance-calendar-due-dates
- TaxGuru SEBI LODR Third Amendment 2024: https://taxguru.in/sebi/highlights-sebi-lodr-regulations-third-amendment-2024.html
- Taxmann EPF Scheme 2026: https://www.taxmann.com/post/blog/government-notifies-epf-scheme/
- Mondaq SEBI LODR Dec 2024: https://webiis08.mondaq.com/india/securities/1580800/navigating-the-sebi-lodr-december-2024-amendment-key-changes
