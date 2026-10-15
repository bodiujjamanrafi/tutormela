// Read the persisted account again before displaying tutor-only navigation.
export async function resolveAccountRole({account,requestedRole,chooseRole,reload}){
 if(!account?.id)throw new Error('Your account could not be opened. Please sign in again.')
 const tutorRequested=requestedRole==='tutor'
 if(account.onboarding_complete===false||(tutorRequested&&account.role==='student')){
  await chooseRole(tutorRequested?'tutor':'student')
  const updated=await reload()
  if(updated?.id!==account.id||(tutorRequested&&updated.role!=='tutor'&&updated.role!=='admin'))throw new Error('Your tutor account could not be activated. Please try again.')
  return updated
 }
 return account
}
