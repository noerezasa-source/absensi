
import 'package:supabase/supabase.dart';
import 'package:flutter/widgets.dart';

Future<void> main() async {
  
    WidgetsFlutterBinding.ensureInitialized();
    final supabase = SupabaseClient(
      'https://oovtwiioyejefifsgrtj.supabase.co',
      'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6Im9vdnR3aWlveWVqZWZpZnNncnRqIiwicm9sZSI6ImFub24iLCJpYXQiOjE3ODAwMTY0MTYsImV4cCI6MjA5NTU5MjQxNn0.BpXzBmlvLZX7f4bRK8IG_JHUKU5qHTsHQ1A2VL-eQZM',
    );

    final res = await supabase.from('biometric_data').select('''
      id,
      template_data,
      organization_member_id,
      organization_members(
        id,
        user_profiles(
          first_name,
          last_name,
          display_name
        )
      )
    ''').eq('is_active', true);

    for (var row in res) {
      final member = row['organization_members'];
      if (member != null) {
        final profile = member['user_profiles'];
        if (profile != null) {
          final fName = profile['first_name']?.toString().toLowerCase() ?? '';
          final lName = profile['last_name']?.toString().toLowerCase() ?? '';
          final dName = profile['display_name']?.toString().toLowerCase() ?? '';
          final name = '$fName $lName $dName';
          
          if (name.contains('akwwan') || name.contains('kahfi') || name.contains('reza') || name.contains('rafa')) {
            final rawData = row['template_data'];
            String snippet = 'null';
            if (rawData != null && rawData.toString().length > 30) {
              snippet = rawData.toString().substring(0, 50);
            }
            print('Name: ${profile['first_name']} ${profile['last_name']} - ${profile['display_name']}');
            print('Emb: $snippet...');
            print('----------------------');
          }
        }
      }
    }
  
}
