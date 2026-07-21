const fs = require('fs');
const https = require('https');

const options = {
  hostname: 'oovtwiioyejefifsgrtj.supabase.co',
  port: 443,
  path: '/rest/v1/biometric_data?select=id,template_data,organization_member_id,organization_members(id,user_profiles(first_name,last_name,display_name))&is_active=eq.true',
  method: 'GET',
  headers: {
    'apikey': 'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6Im9vdnR3aWlveWVqZWZpZnNncnRqIiwicm9sZSI6ImFub24iLCJpYXQiOjE3ODAwMTY0MTYsImV4cCI6MjA5NTU5MjQxNn0.BpXzBmlvLZX7f4bRK8IG_JHUKU5qHTsHQ1A2VL-eQZM',
    'Authorization': 'Bearer eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6Im9vdnR3aWlveWVqZWZpZnNncnRqIiwicm9sZSI6ImFub24iLCJpYXQiOjE3ODAwMTY0MTYsImV4cCI6MjA5NTU5MjQxNn0.BpXzBmlvLZX7f4bRK8IG_JHUKU5qHTsHQ1A2VL-eQZM'
  }
};

const req = https.request(options, (res) => {
  let data = '';
  res.on('data', (chunk) => { data += chunk; });
  res.on('end', () => {
    const json = JSON.parse(data);
    for (const row of json) {
      const member = row.organization_members;
      if (member) {
        const profile = member.user_profiles;
        if (profile) {
          const name = `${profile.first_name || ''} ${profile.last_name || ''} ${profile.display_name || ''}`.toLowerCase();
          if (name.includes('akwwan') || name.includes('kahfi') || name.includes('reza') || name.includes('rafa')) {
            const raw = row.template_data;
            let snippet = 'null';
            if (raw && typeof raw === 'string') {
              snippet = raw.substring(0, 100);
            }
            console.log(`Name: ${profile.first_name} ${profile.last_name} - ${profile.display_name}`);
            console.log(`Emb: ${snippet}...`);
            console.log('----------------------');
          }
        }
      }
    }
  });
});
req.end();
