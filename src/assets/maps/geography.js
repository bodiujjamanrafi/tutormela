// District spellings and division membership follow Bangladesh's National Portal.
// https://bangladesh.gov.bd/views/district-list/
export const districtNamesBn = {
 Bagerhat:'বাগেরহাট',Bandarban:'বান্দরবান',Barguna:'বরগুনা',Barishal:'বরিশাল',Bhola:'ভোলা',Bogura:'বগুড়া',Brahmanbaria:'ব্রাহ্মণবাড়িয়া',Chandpur:'চাঁদপুর',Chapainawabganj:'চাঁপাইনবাবগঞ্জ',Chattogram:'চট্টগ্রাম',Chuadanga:'চুয়াডাঙ্গা','Cox’s Bazar':'কক্সবাজার',Cumilla:'কুমিল্লা',Dhaka:'ঢাকা',Dinajpur:'দিনাজপুর',Faridpur:'ফরিদপুর',Feni:'ফেনী',Gaibandha:'গাইবান্ধা',Gazipur:'গাজীপুর',Gopalganj:'গোপালগঞ্জ',Habiganj:'হবিগঞ্জ',Jamalpur:'জামালপুর',Jashore:'যশোর',Jhalokati:'ঝালকাঠি',Jhenaidah:'ঝিনাইদহ',Joypurhat:'জয়পুরহাট',Khagrachhari:'খাগড়াছড়ি',Khulna:'খুলনা',Kishoreganj:'কিশোরগঞ্জ',Kurigram:'কুড়িগ্রাম',Kushtia:'কুষ্টিয়া',Lakshmipur:'লক্ষ্মীপুর',Lalmonirhat:'লালমনিরহাট',Madaripur:'মাদারীপুর',Magura:'মাগুরা',Manikganj:'মানিকগঞ্জ',Meherpur:'মেহেরপুর',Moulvibazar:'মৌলভীবাজার',Munshiganj:'মুন্সীগঞ্জ',Mymensingh:'ময়মনসিংহ',Naogaon:'নওগাঁ',Narail:'নড়াইল',Narayanganj:'নারায়ণগঞ্জ',Narsingdi:'নরসিংদী',Natore:'নাটোর',Netrokona:'নেত্রকোণা',Nilphamari:'নীলফামারী',Noakhali:'নোয়াখালী',Pabna:'পাবনা',Panchagarh:'পঞ্চগড়',Patuakhali:'পটুয়াখালী',Pirojpur:'পিরোজপুর',Rajbari:'রাজবাড়ী',Rajshahi:'রাজশাহী',Rangamati:'রাঙ্গামাটি',Rangpur:'রংপুর',Satkhira:'সাতক্ষীরা',Shariatpur:'শরীয়তপুর',Sherpur:'শেরপুর',Sirajganj:'সিরাজগঞ্জ',Sunamganj:'সুনামগঞ্জ',Sylhet:'সিলেট',Tangail:'টাঙ্গাইল',Thakurgaon:'ঠাকুরগাঁও'
}
export const divisions = [
 {name:'Dhaka',bn:'ঢাকা',districts:['Dhaka','Faridpur','Gazipur','Gopalganj','Kishoreganj','Madaripur','Manikganj','Munshiganj','Narayanganj','Narsingdi','Rajbari','Shariatpur','Tangail']},
 {name:'Chattogram',bn:'চট্টগ্রাম',districts:['Bandarban','Brahmanbaria','Chandpur','Chattogram','Cumilla','Cox’s Bazar','Feni','Khagrachhari','Lakshmipur','Noakhali','Rangamati']},
 {name:'Rajshahi',bn:'রাজশাহী',districts:['Bogura','Joypurhat','Naogaon','Natore','Chapainawabganj','Pabna','Rajshahi','Sirajganj']},
 {name:'Khulna',bn:'খুলনা',districts:['Bagerhat','Chuadanga','Jashore','Jhenaidah','Khulna','Kushtia','Magura','Meherpur','Narail','Satkhira']},
 {name:'Barishal',bn:'বরিশাল',districts:['Barguna','Barishal','Bhola','Jhalokati','Patuakhali','Pirojpur']},
 {name:'Sylhet',bn:'সিলেট',districts:['Habiganj','Moulvibazar','Sunamganj','Sylhet']},
 {name:'Rangpur',bn:'রংপুর',districts:['Dinajpur','Gaibandha','Kurigram','Lalmonirhat','Nilphamari','Panchagarh','Rangpur','Thakurgaon']},
 {name:'Mymensingh',bn:'ময়মনসিংহ',districts:['Jamalpur','Mymensingh','Netrokona','Sherpur']}
]
export function localizedDistrict(name,lang){return lang==='bn'?(districtNamesBn[name]||name):name}
export function localizedDivision(name,lang){return lang==='bn'?(divisions.find(d=>d.name===name)?.bn||name):name}
