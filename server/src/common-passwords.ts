// Common passwords of 10 or more characters (shorter ones already fail the length check), lower case.
// Drawn from the well-known breach top lists. Short on purpose: the length rule does most of the work.
export const COMMON_PASSWORDS = new Set([
  '1234567890', '0987654321', '12345678910', '123456789a', 'a123456789', '1234567890a', '1234567890q',
  'qwertyuiop', 'qwertyuiop1', '1q2w3e4r5t', '1q2w3e4r5t6y', 'q1w2e3r4t5', 'qazwsxedcrfv', '1qaz2wsx3edc', 'zaq12wsxcde3',
  'asdfghjkl1', 'asdfghjkl;', 'zxcvbnm123', 'qwerty1234', 'qwerty12345', 'qwerty123456', 'asdfasdfasdf',
  'password12', 'password123', 'password1234', 'password12345', 'password!1', 'password1!', 'passw0rd123', 'p@ssw0rd123',
  'p@ssword123', 'passwordpassword', 'mypassword', 'mypassword1', 'mypassword123', 'newpassword', 'newpassword1',
  'changeme123', 'letmein123', 'welcome123', 'welcome1234', 'iloveyou12', 'iloveyou123', 'iloveyou1234',
  'football123', 'baseball123', 'basketball', 'basketball1', 'superman123', 'starwars123', 'princess123',
  'sunshine123', 'computer123', 'administrator', 'admin12345', 'admin123456', 'abcdefghij', 'abcdefghijk',
  'abc1234567', 'abcd123456', 'aaaaaaaaaa', '1111111111', '0000000000', '1234512345', '1122334455',
  'monkey12345', 'dragon12345', 'trustno1234', 'internet123', 'pokemon123', 'liverpool123', 'chelsea123',
  'manchester', 'manchester1', 'jesus12345', 'whatever123', 'pipkeyboard', 'pipkeyboard1', 'pippippip1',
]);
