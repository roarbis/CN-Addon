// ============================================================
//  Connect Nest — Google Apps Script Web App Endpoint
//
//  PURPOSE: Receives POST requests from CN tools and:
//    1. Logs the event to a Google Sheet (audit trail)
//    2. Sends a formatted email to hello@connectnest.com.au
//
//  DEPLOYMENT:
//    - Open script.google.com, create a new project, paste this file
//    - Deploy → New deployment → Web app
//    - Execute as:   Me (your Google account)
//    - Who has access: Anyone
//    - Copy the deployment URL → store in your team password manager
//    - The URL itself is the auth token (unguessable, ~60 char slug)
//
//  SUPPORTED ACTIONS (POST body JSON):
//    action: "ps_summary"  — from CN-PrepCustomerPC.ps1
//    action: "form_config" — from cn-preconfig-form.html
//
//  AUDIT LOG:
//    - On first use, creates a sheet named "CN Setup Log" in this
//      spreadsheet. One row per call: timestamp, action, customer,
//      machine/source, detail.
//    - To view: open the Apps Script project → open linked spreadsheet
//
//  TESTING:
//    - Run testPsSummary() or testFormConfig() from the editor
//      to verify email sending before deploying to team
// ============================================================

const RECIPIENT_EMAIL = 'hello@connectnest.com.au';
const LOG_SHEET_NAME  = 'CN Setup Log';
const TZ              = 'Australia/Melbourne';

// ─── Router ───────────────────────────────────────────────────────────────────
function doPost(e) {
  try {
    const body   = JSON.parse(e.postData.contents);
    const action = (body.action || '').toLowerCase();

    if (action === 'ps_summary') {
      return handlePsSummary(body);
    } else if (action === 'form_config') {
      return handleFormConfig(body);
    } else {
      return jsonResponse({ ok: false, error: 'Unknown action: ' + action });
    }
  } catch (err) {
    return jsonResponse({ ok: false, error: err.toString() });
  }
}

// ─── Handler: PS Script Summary ───────────────────────────────────────────────
// Receives the RustDesk ID + password + full summary text from CN-PrepCustomerPC.ps1
function handlePsSummary(body) {
  const machine     = body.machine      || 'Unknown';
  const customer    = body.customer     || 'Unknown Customer';
  const rustdeskId  = body.rustdesk_id  || '—';
  const rustdeskPwd = body.rustdesk_pwd || '—';
  const summaryText = body.summary      || '';
  const timestamp   = new Date().toISOString();
  const dateStr     = Utilities.formatDate(new Date(), TZ, 'yyyy-MM-dd');

  const subject = `[CN Hub Ready] ${customer} — ${machine} — ${dateStr}`;

  const htmlBody = `
<div style="font-family: Arial, sans-serif; max-width: 620px; margin: 0 auto;">
  <div style="background: #1E2329; padding: 22px 28px; border-radius: 8px 8px 0 0;">
    <h2 style="color: #0D9488; margin: 0; font-size: 1.3rem;">Connect Nest</h2>
    <p style="color: #A0B0C0; margin: 4px 0 0; font-size: 0.9rem;">Customer Hub — Prep Script Complete</p>
  </div>
  <div style="background: #ffffff; border: 1px solid #CBD5E0; border-top: none; padding: 24px 28px; border-radius: 0 0 8px 8px;">

    <h3 style="color: #2D3748; margin: 0 0 12px; font-size: 1rem;">Remote Access Credentials</h3>
    <table style="width: 100%; border-collapse: collapse; margin-bottom: 20px;">
      <tr style="background: #F7FAFC;">
        <td style="padding: 10px 12px; color: #718096; width: 38%; font-size: 0.88rem;">Customer</td>
        <td style="padding: 10px 12px; font-weight: bold;">${escapeHtml(customer)}</td>
      </tr>
      <tr>
        <td style="padding: 10px 12px; color: #718096; font-size: 0.88rem;">Machine</td>
        <td style="padding: 10px 12px;">${escapeHtml(machine)}</td>
      </tr>
      <tr style="background: #F7FAFC;">
        <td style="padding: 10px 12px; color: #718096; font-size: 0.88rem;">RustDesk ID</td>
        <td style="padding: 10px 12px; font-size: 1.15rem; font-weight: bold; color: #0D9488; font-family: monospace;">${escapeHtml(rustdeskId)}</td>
      </tr>
      <tr>
        <td style="padding: 10px 12px; color: #718096; font-size: 0.88rem;">RustDesk Password</td>
        <td style="padding: 10px 12px; font-size: 1.15rem; font-weight: bold; color: #0D9488; font-family: monospace;">${escapeHtml(rustdeskPwd)}</td>
      </tr>
      <tr style="background: #F7FAFC;">
        <td style="padding: 10px 12px; color: #718096; font-size: 0.88rem;">Timestamp</td>
        <td style="padding: 10px 12px; font-size: 0.88rem;">${timestamp}</td>
      </tr>
    </table>

    ${summaryText ? `
    <hr style="border: none; border-top: 1px solid #EDF2F7; margin: 0 0 20px;">
    <h3 style="color: #2D3748; margin: 0 0 10px; font-size: 1rem;">Full Setup Log</h3>
    <pre style="background: #F7FAFC; border: 1px solid #EDF2F7; padding: 16px; border-radius: 6px; font-size: 0.8rem; overflow: auto; white-space: pre-wrap; color: #2D3748;">${escapeHtml(summaryText)}</pre>
    ` : ''}

    <p style="font-size: 0.78rem; color: #A0B0C0; margin-top: 16px; padding-top: 12px; border-top: 1px solid #EDF2F7;">
      Sent automatically by CN-PrepCustomerPC.ps1
    </p>
  </div>
</div>`;

  GmailApp.sendEmail(RECIPIENT_EMAIL, subject, `RustDesk ID: ${rustdeskId}\nPassword: ${rustdeskPwd}\n\n${summaryText}`, {
    htmlBody,
    name: 'Connect Nest Automation'
  });

  logToSheet(timestamp, 'ps_summary', customer, machine, `RustDesk: ${rustdeskId}`);

  return jsonResponse({ ok: true, message: 'Setup summary email sent' });
}

// ─── Handler: Form Config JSON ────────────────────────────────────────────────
// Receives the pre-config JSON from cn-preconfig-form.html "Email JSON" button
function handleFormConfig(body) {
  const cfg      = body.config || {};
  const meta     = cfg._meta  || {};
  const network  = cfg.network || {};
  const zigbee   = cfg.zigbee  || {};
  const mqtt     = cfg.mqtt    || {};
  const options  = cfg.options || {};

  const customer    = meta.customer_name || 'Unknown Customer';
  const sentFrom    = body.sent_from     || 'Pre-Config Form';
  const timestamp   = new Date().toISOString();
  const dateStr     = Utilities.formatDate(new Date(), TZ, 'yyyy-MM-dd');
  const installDate = meta.install_date  || dateStr;

  const subject = `[CN Config] ${customer} — ${installDate}`;

  // Formatted config for email
  const configJson = JSON.stringify(cfg, null, 2);

  const row = (label, value, alt) => `
    <tr style="${alt ? 'background: #F7FAFC;' : ''}">
      <td style="padding: 8px 12px; color: #718096; width: 38%; font-size: 0.88rem;">${label}</td>
      <td style="padding: 8px 12px;">${escapeHtml(String(value || '—'))}</td>
    </tr>`;

  const htmlBody = `
<div style="font-family: Arial, sans-serif; max-width: 620px; margin: 0 auto;">
  <div style="background: #1E2329; padding: 22px 28px; border-radius: 8px 8px 0 0;">
    <h2 style="color: #0D9488; margin: 0; font-size: 1.3rem;">Connect Nest</h2>
    <p style="color: #A0B0C0; margin: 4px 0 0; font-size: 0.9rem;">Pre-Config — ${escapeHtml(customer)}</p>
  </div>
  <div style="background: #ffffff; border: 1px solid #CBD5E0; border-top: none; padding: 24px 28px; border-radius: 0 0 8px 8px;">

    <h3 style="color: #2D3748; margin: 0 0 12px; font-size: 1rem;">Job Details</h3>
    <table style="width: 100%; border-collapse: collapse; margin-bottom: 20px;">
      ${row('Customer',     customer, false)}
      ${row('Install Date', installDate, true)}
      ${row('Site Address', meta.site_address, false)}
    </table>

    <h3 style="color: #2D3748; margin: 0 0 12px; font-size: 1rem;">Network</h3>
    <table style="width: 100%; border-collapse: collapse; margin-bottom: 20px;">
      ${row('Hub Static IP',  network.hub_static_ip, false)}
      ${row('Gateway',        network.gateway, true)}
      ${row('Subnet Mask',    network.subnet_mask, false)}
      ${row('DNS',            (network.dns1 || '') + (network.dns2 ? ' / ' + network.dns2 : ''), true)}
      ${row('Location',       network.location_city, false)}
    </table>

    <h3 style="color: #2D3748; margin: 0 0 12px; font-size: 1rem;">Credentials</h3>
    <table style="width: 100%; border-collapse: collapse; margin-bottom: 20px;">
      ${row('Zigbee Coordinator', (zigbee.coordinator_ip || '—') + ':' + (zigbee.coordinator_port || 6638), false)}
      ${row('MQTT Username',  mqtt.username, true)}
      ${row('MQTT Password',  mqtt.password, false)}
    </table>

    <h3 style="color: #2D3748; margin: 0 0 12px; font-size: 1rem;">Options</h3>
    <table style="width: 100%; border-collapse: collapse; margin-bottom: 20px;">
      ${row('Studio Code',   options.install_studio_code ? '✓ Install' : '✗ Skip', false)}
      ${row('HACS',          options.install_hacs        ? '✓ Install' : '✗ Skip', true)}
      ${row('Tailscale',     options.install_tailscale   ? '✓ Install' : '✗ Skip', false)}
      ${row('OneDrive',      options.install_onedrive    ? '✓ Install' : '✗ Skip', true)}
      ${row('Backup',        (options.backup_schedule || '—') + ' (keep ' + (options.backup_copies || 3) + ')', false)}
    </table>

    <hr style="border: none; border-top: 1px solid #EDF2F7; margin: 0 0 20px;">
    <h3 style="color: #2D3748; margin: 0 0 10px; font-size: 1rem;">Full Config JSON</h3>
    <pre style="background: #F7FAFC; border: 1px solid #EDF2F7; padding: 16px; border-radius: 6px; font-size: 0.8rem; overflow: auto; white-space: pre-wrap; color: #2D3748;">${escapeHtml(configJson)}</pre>

    <p style="font-size: 0.78rem; color: #A0B0C0; margin-top: 16px; padding-top: 12px; border-top: 1px solid #EDF2F7;">
      ⚠ Contains MQTT password — do not forward publicly.<br>
      Sent from CN Pre-Config Form | ${timestamp}
    </p>
  </div>
</div>`;

  GmailApp.sendEmail(RECIPIENT_EMAIL, subject, configJson, {
    htmlBody,
    name: 'Connect Nest Automation'
  });

  logToSheet(timestamp, 'form_config', customer, sentFrom, network.hub_static_ip || '—');

  return jsonResponse({ ok: true, message: 'Config email sent' });
}

// ─── Sheet Logging ────────────────────────────────────────────────────────────
function logToSheet(timestamp, action, customer, source, detail) {
  try {
    const ss  = SpreadsheetApp.getActiveSpreadsheet();
    let sheet = ss.getSheetByName(LOG_SHEET_NAME);

    if (!sheet) {
      sheet = ss.insertSheet(LOG_SHEET_NAME);
      const header = sheet.getRange(1, 1, 1, 5);
      header.setValues([['Timestamp', 'Action', 'Customer', 'Machine / Source', 'Detail']]);
      header.setFontWeight('bold');
      header.setBackground('#1E2329');
      header.setFontColor('#0D9488');
      sheet.setFrozenRows(1);
      sheet.setColumnWidth(1, 200);
      sheet.setColumnWidth(3, 180);
    }

    sheet.appendRow([timestamp, action, customer, source, detail]);
  } catch (err) {
    // Non-fatal — email already sent, just log warning
    console.warn('Sheet logging failed (non-fatal):', err);
  }
}

// ─── Helpers ──────────────────────────────────────────────────────────────────
function jsonResponse(obj) {
  return ContentService
    .createTextOutput(JSON.stringify(obj))
    .setMimeType(ContentService.MimeType.JSON);
}

function escapeHtml(str) {
  return String(str)
    .replace(/&/g,  '&amp;')
    .replace(/</g,  '&lt;')
    .replace(/>/g,  '&gt;')
    .replace(/"/g,  '&quot;');
}

// ─── Test Functions (run from Apps Script editor to verify) ───────────────────
function testPsSummary() {
  const e = {
    postData: {
      contents: JSON.stringify({
        action:       'ps_summary',
        customer:     'Smith Family',
        machine:      'SMITH-PC',
        rustdesk_id:  '123 456 789',
        rustdesk_pwd: 'TestPass123',
        summary:      'CONNECT NEST — SETUP SUMMARY\n  Generated: 2026-04-06 14:30:00\n  Machine:   SMITH-PC\n\nVIRTUALBOX VM\n  Status: Started headless\n\nRUSTDESK REMOTE ACCESS\n  RustDesk ID: 123 456 789\n  Password:    TestPass123'
      })
    }
  };
  const result = doPost(e);
  Logger.log(result.getContent());
}

function testFormConfig() {
  const e = {
    postData: {
      contents: JSON.stringify({
        action:    'form_config',
        sent_from: 'cn-preconfig-form.html (manual test)',
        config: {
          _meta:   { version: '1.0', generated_at: new Date().toISOString(), customer_name: 'Jones Family', install_date: '08/04/2026', site_address: '42 Somewhere St, Melbourne VIC 3000' },
          network: { hub_static_ip: '192.168.1.50', gateway: '192.168.1.1', subnet_mask: '255.255.255.0', dns1: '8.8.8.8', dns2: '8.8.4.4', location_city: 'Melbourne, Victoria' },
          zigbee:  { coordinator_ip: '192.168.1.75', coordinator_port: 6638, adapter: 'ember' },
          mqtt:    { username: 'cn_mqtt', password: 'Abc123xyz456!' },
          options: { install_studio_code: true, install_hacs: true, install_tailscale: true, install_onedrive: false, backup_schedule: 'daily', backup_copies: 3 }
        }
      })
    }
  };
  const result = doPost(e);
  Logger.log(result.getContent());
}
